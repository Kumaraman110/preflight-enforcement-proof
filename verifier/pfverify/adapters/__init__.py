"""Producer adapters — each bridges an EXISTING enforcement surface into the
model-neutral protocol. An adapter is a PRODUCER of Action Intents + Evidence
Bundles; it is NOT the platform core. The server-authoritative verifier
(pfverify.engine) is the core and treats every adapter's output as untrusted
input to be independently re-verified.
"""
