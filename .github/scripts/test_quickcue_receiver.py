import base64
import hashlib
import hmac
import importlib.util
import json
import pathlib
import tempfile
import unittest
import uuid
import zipfile
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "quickcue_receiver", ROOT / "tools/quickcue_receiver/receiver.py"
)
RECEIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIVER)


def client_packet(receiver_id, public_key, kind, payload):
    receiver = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), RECEIVER.unb64url(public_key))
    ephemeral = ec.generate_private_key(ec.SECP256R1())
    shared = ephemeral.exchange(ec.ECDH(), receiver)
    key = HKDF(
        algorithm=hashes.SHA256(), length=32,
        salt=receiver_id.lower().encode(), info=f"QuickCue-{kind}-v1".encode(),
    ).derive(shared)
    plaintext = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    nonce = bytes(range(12))
    combined = nonce + ChaCha20Poly1305(key).encrypt(nonce, plaintext, None)
    outer = {
        "schemaVersion": 1,
        "kind": kind,
        "receiverID": receiver_id,
        "ephemeralPublicKey": RECEIVER.b64url(ephemeral.public_key().public_bytes(
            serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
        )),
        "sealedPayload": RECEIVER.b64url(combined),
    }
    return json.dumps(outer, sort_keys=True, separators=(",", ":")).encode()


def diagnostic_archive(export_id):
    event = json.dumps({
        "schemaVersion": 1, "id": str(uuid.uuid4()), "occurredAt": "2026-09-06T00:00:00Z",
        "appVersion": "0.3.1", "appBuild": "7", "sourceRevision": "abcdef0",
        "osVersion": "26.0", "deviceFamily": "iPhone", "kind": "sessionEnded",
        "sessionID": str(uuid.uuid4()),
    }, separators=(",", ":")).encode() + b"\n"
    summary = json.dumps({
        "schemaVersion": 1, "exportID": export_id, "eventCount": 1, "droppedEvents": 0,
        "buildCounts": {"0.3.1 (7)": 1}, "errorCounts": {},
        "latency": {"sampleCount": 0, "p50Milliseconds": None, "p95Milliseconds": None},
    }, separators=(",", ":")).encode()
    manifest = json.dumps({
        "schemaVersion": 1, "exportID": export_id, "createdAt": "2026-09-06T00:00:00Z",
        "files": [
            {"name": "events.jsonl", "byteCount": len(event), "sha256": hashlib.sha256(event).hexdigest()},
            {"name": "summary.json", "byteCount": len(summary), "sha256": hashlib.sha256(summary).hexdigest()},
        ],
    }, separators=(",", ":")).encode()
    with tempfile.TemporaryDirectory() as folder:
        target = pathlib.Path(folder) / "fixture.quickcue-diagnostics"
        with zipfile.ZipFile(target, "w") as archive:
            archive.writestr("manifest.json", manifest)
            archive.writestr("events.jsonl", event)
            archive.writestr("summary.json", summary)
        return target.read_bytes()


class ReceiverTests(unittest.TestCase):
    def test_duplicate_packet_field_is_rejected(self):
        with self.assertRaisesRegex(RECEIVER.ReceiverError, "duplicate field"):
            RECEIVER._strict_object(b'{"kind":"pair","kind":"report"}', {"kind"}, "packet")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.store = RECEIVER.StateStore(self.root, protector=lambda value: value, unprotector=lambda value: value)
        self.state = RECEIVER.new_state()
        self.code, self.state = RECEIVER.invitation(
            self.state, "192.168.1.10", 43117,
            now=datetime(2026, 9, 6, tzinfo=timezone.utc),
        )
        self.store.save(self.state)
        encoded = self.code.removeprefix("quickcue-pair:")
        self.invite = json.loads(RECEIVER.unb64url(encoded))
        self.pair_id = str(uuid.uuid4())
        self.delivery_secret = bytes(range(32))

    def tearDown(self):
        self.temporary.cleanup()

    def pair(self):
        payload = {
            "schemaVersion": 1,
            "pairID": self.pair_id,
            "oneTimeSecret": self.invite["oneTimeSecret"],
            "deliverySecret": RECEIVER.b64url(self.delivery_secret),
        }
        packet = client_packet(self.state["receiverID"], self.invite["publicKey"], "pair", payload)
        response = json.loads(RECEIVER.handle_packet(
            packet, self.store, self.root / "Inbox",
            now=datetime(2026, 9, 6, 0, 1, tzinfo=timezone.utc),
        ))
        message = f"v1|paired|{self.state['receiverID'].lower()}|{self.pair_id.lower()}".encode()
        expected = RECEIVER.b64url(hmac.new(self.delivery_secret, message, hashlib.sha256).digest())
        self.assertEqual(response["authenticationCode"], expected)

    def test_pair_delivery_replay_and_revoke(self):
        self.pair()
        export_id = str(uuid.uuid4())
        archive = diagnostic_archive(export_id)
        payload = {
            "schemaVersion": 1, "pairID": self.pair_id,
            "deliverySecret": RECEIVER.b64url(self.delivery_secret),
            "exportID": export_id, "archive": base64.b64encode(archive).decode(),
        }
        packet = client_packet(self.state["receiverID"], self.invite["publicKey"], "report", payload)
        first = RECEIVER.handle_packet(packet, self.store, self.root / "Inbox")
        second = RECEIVER.handle_packet(packet, self.store, self.root / "Inbox")
        self.assertEqual(json.loads(first)["status"], "stored")
        self.assertEqual(json.loads(second)["status"], "stored")
        self.assertEqual(len(list((self.root / "Inbox").glob("*.quickcue-diagnostics"))), 1)

        state = self.store.load()
        del state["pairs"][self.pair_id]
        self.store.save(state)
        with self.assertRaisesRegex(RECEIVER.ReceiverError, "revoked"):
            RECEIVER.handle_packet(packet, self.store, self.root / "Inbox")

    def test_expired_pair_code_is_rejected(self):
        payload = {
            "schemaVersion": 1, "pairID": self.pair_id,
            "oneTimeSecret": self.invite["oneTimeSecret"],
            "deliverySecret": RECEIVER.b64url(self.delivery_secret),
        }
        packet = client_packet(self.state["receiverID"], self.invite["publicKey"], "pair", payload)
        with self.assertRaisesRegex(RECEIVER.ReceiverError, "expired"):
            RECEIVER.handle_packet(
                packet, self.store, self.root / "Inbox",
                now=datetime(2026, 9, 6, 0, 11, tzinfo=timezone.utc),
            )

    def test_pairing_payload_rejects_command_field(self):
        payload = {
            "schemaVersion": 1, "pairID": self.pair_id,
            "oneTimeSecret": self.invite["oneTimeSecret"],
            "deliverySecret": RECEIVER.b64url(self.delivery_secret),
            "command": "change-provider",
        }
        packet = client_packet(self.state["receiverID"], self.invite["publicKey"], "pair", payload)
        with self.assertRaisesRegex(RECEIVER.ReceiverError, "fields"):
            RECEIVER.handle_packet(packet, self.store, self.root / "Inbox")

    def test_public_or_wildcard_receiver_address_is_rejected(self):
        for host in ("0.0.0.0", "8.8.8.8", "example.com", "127.0.0.1"):
            with self.subTest(host=host), self.assertRaisesRegex(RECEIVER.ReceiverError, "private-LAN"):
                RECEIVER.invitation(self.state, host, 43117)


if __name__ == "__main__":
    unittest.main()
