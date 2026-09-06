#!/usr/bin/env python3
"""QuickCue's one-way encrypted LAN diagnostics receiver for Windows."""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import hmac
import ipaddress
import json
import os
import pathlib
import socket
import socketserver
import struct
import sys
import tempfile
import threading
import uuid
import zipfile
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from analyze_quickcue_diagnostics import InvalidDiagnostics, analyze  # noqa: E402

MAX_PACKET = 20 * 1024 * 1024
MAX_ARCHIVE = 12 * 1024 * 1024
STATE_VERSION = 1


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * ((4 - len(text) % 4) % 4))


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class ReceiverError(ValueError):
    pass


def require_private_lan_ipv4(host: str) -> str:
    try:
        address = ipaddress.IPv4Address(host)
    except ipaddress.AddressValueError as exc:
        raise ReceiverError("host must be one private-LAN IPv4 address") from exc
    private_ranges = (
        ipaddress.IPv4Network("10.0.0.0/8"),
        ipaddress.IPv4Network("172.16.0.0/12"),
        ipaddress.IPv4Network("192.168.0.0/16"),
    )
    if not any(address in network for network in private_ranges):
        raise ReceiverError("host must be one private-LAN IPv4 address")
    return str(address)


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_ulong), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _blob(data: bytes):
    buffer = ctypes.create_string_buffer(data)
    return DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte))), buffer


def dpapi_protect(data: bytes) -> bytes:
    if os.name != "nt":
        raise ReceiverError("Windows DPAPI is required outside tests")
    source, keepalive = _blob(data)
    output = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(source), "QuickCue Receiver", None, None, None, 0, ctypes.byref(output)
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(output.pbData, output.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(output.pbData)


def dpapi_unprotect(data: bytes) -> bytes:
    if os.name != "nt":
        raise ReceiverError("Windows DPAPI is required outside tests")
    source, keepalive = _blob(data)
    output = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(source), None, None, None, None, 0, ctypes.byref(output)
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(output.pbData, output.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(output.pbData)


class StateStore:
    def __init__(self, root: pathlib.Path, protector=dpapi_protect, unprotector=dpapi_unprotect):
        self.root = root
        self.path = root / "receiver-state.dpapi"
        self.protector = protector
        self.unprotector = unprotector
        self.lock = threading.Lock()

    def load(self) -> dict:
        with self.lock:
            if not self.path.exists():
                raise ReceiverError("receiver is not initialized")
            return json.loads(self.unprotector(self.path.read_bytes()))

    def save(self, state: dict) -> None:
        with self.lock:
            self.root.mkdir(parents=True, exist_ok=True)
            protected = self.protector(json.dumps(state, sort_keys=True, separators=(",", ":")).encode())
            temporary = self.path.with_suffix(".tmp")
            temporary.write_bytes(protected)
            os.replace(temporary, self.path)


def new_state() -> dict:
    private = ec.generate_private_key(ec.SECP256R1())
    private_der = private.private_bytes(
        serialization.Encoding.DER,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return {
        "schemaVersion": STATE_VERSION,
        "receiverID": str(uuid.uuid4()),
        "privateKey": b64url(private_der),
        "invitationHash": None,
        "invitationExpiresAt": None,
        "pairs": {},
        "seenExports": [],
    }


def invitation(state: dict, host: str, port: int, now: datetime | None = None) -> tuple[str, dict]:
    host = require_private_lan_ipv4(host)
    if not 0 < port <= 65535:
        raise ReceiverError("port is invalid")
    now = now or datetime.now(timezone.utc)
    secret = os.urandom(32)
    expires = now + timedelta(minutes=10)
    private = serialization.load_der_private_key(unb64url(state["privateKey"]), password=None)
    public = private.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    body = {
        "schemaVersion": 1,
        "receiverID": state["receiverID"],
        "host": host,
        "port": port,
        "publicKey": b64url(public),
        "oneTimeSecret": b64url(secret),
        "expiresAt": iso(expires),
    }
    state["invitationHash"] = hashlib.sha256(secret).hexdigest()
    state["invitationExpiresAt"] = iso(expires)
    encoded = b64url(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
    return "quickcue-pair:" + encoded, state


def _strict_object(data: bytes, keys: set[str], name: str) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ReceiverError(f"invalid {name} duplicate field")
            value[key] = item
        return value

    try:
        value = json.loads(data, object_pairs_hook=unique)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReceiverError(f"invalid {name}") from exc
    if not isinstance(value, dict) or set(value) != keys:
        raise ReceiverError(f"invalid {name} fields")
    return value


def decrypt_packet(packet: bytes, state: dict) -> tuple[str, dict]:
    outer = _strict_object(
        packet,
        {"schemaVersion", "kind", "receiverID", "ephemeralPublicKey", "sealedPayload"},
        "packet",
    )
    if outer["schemaVersion"] != 1 or outer["receiverID"] != state["receiverID"]:
        raise ReceiverError("wrong receiver")
    kind = outer["kind"]
    if kind not in {"pair", "report"}:
        raise ReceiverError("unsupported packet kind")
    private = serialization.load_der_private_key(unb64url(state["privateKey"]), password=None)
    ephemeral = ec.EllipticCurvePublicKey.from_encoded_point(
        ec.SECP256R1(), unb64url(outer["ephemeralPublicKey"])
    )
    shared = private.exchange(ec.ECDH(), ephemeral)
    key = HKDF(
        algorithm=hashes.SHA256(), length=32,
        salt=state["receiverID"].lower().encode(),
        info=f"QuickCue-{kind}-v1".encode(),
    ).derive(shared)
    combined = unb64url(outer["sealedPayload"])
    if len(combined) < 12 + 16:
        raise ReceiverError("invalid encrypted payload")
    plaintext = ChaCha20Poly1305(key).decrypt(combined[:12], combined[12:], None)
    expected = (
        {"schemaVersion", "pairID", "oneTimeSecret", "deliverySecret"}
        if kind == "pair"
        else {"schemaVersion", "pairID", "deliverySecret", "exportID", "archive"}
    )
    return kind, _strict_object(plaintext, expected, f"{kind} payload")


def acknowledgement(status: str, receiver_id: str, reference_id: str, secret: bytes) -> bytes:
    message = f"v1|{status}|{receiver_id.lower()}|{reference_id.lower()}".encode()
    body = {
        "schemaVersion": 1,
        "status": status,
        "receiverID": receiver_id,
        "referenceID": reference_id,
        "authenticationCode": b64url(hmac.new(secret, message, hashlib.sha256).digest()),
    }
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()


def handle_packet(packet: bytes, store: StateStore, inbox: pathlib.Path, now: datetime | None = None) -> bytes:
    now = now or datetime.now(timezone.utc)
    state = store.load()
    kind, payload = decrypt_packet(packet, state)
    if payload.get("schemaVersion") != 1:
        raise ReceiverError("unsupported payload schema")

    if kind == "pair":
        expires_text = state.get("invitationExpiresAt")
        expires = datetime.fromisoformat(expires_text.replace("Z", "+00:00")) if expires_text else now
        supplied = unb64url(payload["oneTimeSecret"])
        delivery_secret = unb64url(payload["deliverySecret"])
        if expires <= now or not state.get("invitationHash"):
            raise ReceiverError("invitation expired")
        if not hmac.compare_digest(hashlib.sha256(supplied).hexdigest(), state["invitationHash"]):
            raise ReceiverError("wrong one-time secret")
        if len(delivery_secret) != 32:
            raise ReceiverError("invalid delivery secret")
        uuid.UUID(payload["pairID"])
        state["pairs"][payload["pairID"]] = payload["deliverySecret"]
        state["invitationHash"] = None
        state["invitationExpiresAt"] = None
        store.save(state)
        return acknowledgement("paired", state["receiverID"], payload["pairID"], delivery_secret)

    pair_secret_text = state["pairs"].get(payload["pairID"])
    if not pair_secret_text or not hmac.compare_digest(pair_secret_text, payload["deliverySecret"]):
        raise ReceiverError("unknown or revoked pair")
    secret = unb64url(pair_secret_text)
    export_id = str(uuid.UUID(payload["exportID"]))
    archive = base64.b64decode(payload["archive"])
    if len(archive) > MAX_ARCHIVE:
        raise ReceiverError("archive too large")

    seen = state.get("seenExports", [])
    if export_id not in seen:
        inbox.mkdir(parents=True, exist_ok=True)
        destination = inbox / f"{export_id}.quickcue-diagnostics"
        with tempfile.NamedTemporaryFile(dir=inbox, suffix=".incoming", delete=False) as temporary:
            temporary.write(archive)
            temporary_path = pathlib.Path(temporary.name)
        try:
            analyze(temporary_path)
            with zipfile.ZipFile(temporary_path) as source:
                manifest = json.loads(source.read("manifest.json"))
            if manifest.get("exportID", "").lower() != export_id.lower():
                raise ReceiverError("archive export ID mismatch")
            os.replace(temporary_path, destination)
        except (InvalidDiagnostics, OSError, zipfile.BadZipFile, json.JSONDecodeError):
            temporary_path.unlink(missing_ok=True)
            raise ReceiverError("diagnostic archive rejected")
        state["seenExports"] = (seen + [export_id])[-500:]
        store.save(state)
    return acknowledgement("stored", state["receiverID"], export_id, secret)


class Handler(socketserver.BaseRequestHandler):
    store: StateStore
    inbox: pathlib.Path

    def handle(self):
        try:
            header = self._read_exact(4)
            length = struct.unpack("!I", header)[0]
            if not 0 < length <= MAX_PACKET:
                raise ReceiverError("invalid packet length")
            response = handle_packet(self._read_exact(length), self.store, self.inbox)
        except Exception:
            # A fixed error avoids reflecting attacker-controlled input or internal details.
            response = b'{"schemaVersion":1,"status":"rejected"}'
        self.request.sendall(struct.pack("!I", len(response)) + response)

    def _read_exact(self, length: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < length:
            chunk = self.request.recv(length - len(chunks))
            if not chunk:
                raise ReceiverError("connection ended early")
            chunks.extend(chunk)
        return bytes(chunks)


def default_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("LOCALAPPDATA", pathlib.Path.home())) / "QuickCueReceiver"


def command_init(args) -> int:
    store = StateStore(args.data_dir)
    if store.path.exists() and not args.force:
        print("Receiver already initialized. Use --force only if you intend to revoke all prior pairs.")
        return 1
    store.save(new_state())
    print(f"Initialized protected receiver state in {store.path.parent}")
    return 0


def command_invite(args) -> int:
    store = StateStore(args.data_dir)
    state = store.load()
    code, state = invitation(state, args.host, args.port)
    store.save(state)
    output = args.data_dir / "pairing-qr.png"
    try:
        import qrcode
        qrcode.make(code).save(output)
        print(f"Open this QR on the PC and scan it in QuickCue: {output}")
    except ImportError:
        print("QR package is missing; install requirements.txt or paste the one-time code below.")
    print(code)
    print("The code expires in 10 minutes. Do not send it to anyone.")
    return 0


def command_serve(args) -> int:
    store = StateStore(args.data_dir)
    store.load()
    host = require_private_lan_ipv4(args.host)
    Handler.store = store
    Handler.inbox = args.data_dir / "Inbox"
    with socketserver.ThreadingTCPServer((host, args.port), Handler) as server:
        server.daemon_threads = True
        print(f"QuickCue receiver listening only on {host}:{args.port}")
        print(f"Validated reports are stored in {Handler.inbox}")
        server.serve_forever()
    return 0


def command_revoke(args) -> int:
    store = StateStore(args.data_dir)
    state = store.load()
    if args.pair_id not in state["pairs"]:
        print("Pair not found")
        return 1
    del state["pairs"][args.pair_id]
    store.save(state)
    print("Pair revoked on this PC")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Encrypted one-way QuickCue diagnostics receiver")
    parser.add_argument("--data-dir", type=pathlib.Path, default=default_root())
    sub = parser.add_subparsers(dest="command", required=True)
    init_parser = sub.add_parser("init")
    init_parser.add_argument("--force", action="store_true")
    init_parser.set_defaults(function=command_init)
    invite_parser = sub.add_parser("invite")
    invite_parser.add_argument("--host", required=True, help="One private-LAN IPv4 address of this PC")
    invite_parser.add_argument("--port", type=int, default=43117)
    invite_parser.set_defaults(function=command_invite)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--host", required=True, help="The same private-LAN IPv4 address used in the QR")
    serve_parser.add_argument("--port", type=int, default=43117)
    serve_parser.set_defaults(function=command_serve)
    revoke_parser = sub.add_parser("revoke")
    revoke_parser.add_argument("pair_id")
    revoke_parser.set_defaults(function=command_revoke)
    args = parser.parse_args()
    return args.function(args)


if __name__ == "__main__":
    raise SystemExit(main())
