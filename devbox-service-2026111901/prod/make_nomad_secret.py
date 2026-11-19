#!/usr/bin/env python3
import argparse
import base64
import os
import re
from pathlib import Path

DIRECTORY = Path(__file__).resolve().parent
OUTPUT = DIRECTORY / "devbox-service-nomad-certs.yaml"
CERTIFICATE = b"-----BEGIN CERTIFICATE-----"
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
CA_FILENAME = re.compile(r"(?:^|[._-])ca(?:[._-]|$)", re.IGNORECASE)


def discover():
    certificates = {}
    private_keys = {}
    for path in DIRECTORY.iterdir():
        if not path.is_file() or path.suffix.lower() not in {".pem", ".crt", ".cer", ".key"}:
            continue
        contents = path.read_bytes()
        if CERTIFICATE in contents:
            certificates[path] = contents
        if PRIVATE_KEY.search(contents):
            private_keys[path] = contents

    cas = [path for path in certificates if CA_FILENAME.search(path.name)]
    clients = [path for path in certificates if path not in cas]
    if len(cas) != 1 or len(clients) != 1 or len(private_keys) != 1:
        raise ValueError("无法唯一识别文件。请按 CA、客户端证书、客户端私钥的顺序指定三个文件名。")
    return certificates[cas[0]], certificates[clients[0]], next(iter(private_keys.values()))


def main():
    parser = argparse.ArgumentParser(description="生成 DevBox 的 Nomad TLS Secret YAML")
    parser.add_argument("files", metavar="PEM", nargs="*", help="依次填写 CA、客户端证书、客户端私钥")
    args = parser.parse_args()
    if args.files and len(args.files) != 3:
        parser.error("请提供三个文件，或者省略文件名以自动识别。")

    try:
        if args.files:
            ca, cert, key = ((DIRECTORY / name).read_bytes() for name in args.files)
        else:
            ca, cert, key = discover()

        if (CERTIFICATE not in ca or CERTIFICATE not in cert or ca == cert
                or PRIVATE_KEY.search(ca) or PRIVATE_KEY.search(cert)
                or not PRIVATE_KEY.search(key) or CERTIFICATE in key):
            raise ValueError("证书或私钥格式不符，请核对三个 PEM 文件及其顺序。")
        if b"ENCRYPTED" in key:
            raise ValueError("客户端私钥带密码，服务需要可直接读取的 PEM 私钥。")

        lines = [
            "apiVersion: v1",
            "kind: Secret",
            "metadata:",
            "  name: devbox-service-nomad-certs",
            "  namespace: devbox-infra",
            "type: Opaque",
            "data:",
        ]
        for name, data in (("ca.pem", ca), ("client-cert.pem", cert), ("client-key.pem", key)):
            encoded = base64.b64encode(data).decode("ascii")
            lines.append(f'  {name}: "{encoded}"')

        fd = os.open(OUTPUT, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
    except (OSError, ValueError) as err:
        parser.exit(1, f"生成失败：{err}\n")
    print(f"已生成：{OUTPUT}")


if __name__ == "__main__":
    main()
