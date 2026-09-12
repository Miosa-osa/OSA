"""Verify the shipped helper without executing or extracting archive contents."""
import hashlib
from pathlib import Path, PurePosixPath
import struct
import sys
import tarfile

NAME = "osa-screen-capture-wayland"
MAX_HELPER_BYTES = 64 * 1024 * 1024


def verify(archive, architecture, built, requirements):
    machine = {"x64": 62, "arm64": 183}.get(architecture)
    if machine is None:
        raise ValueError("unsupported helper architecture")
    expected = Path(built).read_bytes()
    with tarfile.open(archive, "r:gz") as tar:
        helpers = []
        for member in tar:
            path = PurePosixPath(member.name)
            if path.name == NAME:
                helpers.append(member)
        if len(helpers) != 1:
            raise ValueError("release must contain exactly one Wayland helper")
        member = helpers[0]
        parts = PurePosixPath(member.name).parts
        if not (len(parts) == 5 and parts[0] == "lib" and parts[1].startswith("optimal_system_agent-") and parts[2:4] == ("priv", "helpers")):
            raise ValueError("helper is not inside the OSA application priv/helpers")
        if not member.isfile() or not member.mode & 0o111 or not 0 < member.size <= MAX_HELPER_BYTES:
            raise ValueError("helper must be a bounded executable regular file")
        payload = tar.extractfile(member).read(MAX_HELPER_BYTES + 1)
        if len(payload) < 20 or payload[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", payload, 18)[0] != machine:
            raise ValueError("helper ELF architecture does not match release")
        if payload != expected:
            raise ValueError("packaged helper differs from the current build")
        doc_name = str(PurePosixPath(member.name).with_name(NAME + ".runtime.md"))
        docs = [m for m in tar.getmembers() if str(PurePosixPath(m.name)) == doc_name]
        if len(docs) != 1 or not docs[0].isfile() or docs[0].size > 65536:
            raise ValueError("missing or invalid bundled runtime requirements")
        if tar.extractfile(docs[0]).read(65537) != Path(requirements).read_bytes():
            raise ValueError("bundled runtime requirements are stale")
    print(f"Verified {architecture} Wayland helper: {hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
    except (ValueError, OSError, tarfile.TarError, TypeError) as error:
        print(f"Wayland packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
