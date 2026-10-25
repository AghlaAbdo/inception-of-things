#!/usr/bin/env python3
"""Create dependency credentials once, without writing secrets to the repository."""
import base64
import json
import os
import secrets
import subprocess


def kube(*args, **kwargs):
    return subprocess.run(
        ['kubectl', '--context', os.environ['CONTEXT'], '-n', 'gitlab', *args],
        check=True, **kwargs,
    )


def ensure(name, values):
    existing = kube('get', 'secret', name, '--ignore-not-found', '-o', 'json',
                    capture_output=True, text=True).stdout
    if existing.strip():
        return {key: base64.b64decode(value).decode()
                for key, value in json.loads(existing)['data'].items()}
    resource = {'apiVersion': 'v1', 'kind': 'Secret',
                'metadata': {'name': name, 'namespace': 'gitlab'},
                'type': 'Opaque', 'stringData': values}
    kube('create', '-f', '-', input=json.dumps(resource), text=True,
         stdout=subprocess.DEVNULL)
    return values


if __name__ == '__main__':
    ensure('lab-postgresql', {'password': secrets.token_hex(32)})
    ensure('lab-redis', {'password': secrets.token_hex(32)})
    s3 = ensure('lab-s3', {'accesskey': 'GK' + secrets.token_hex(12),
                         'secretkey': secrets.token_hex(32),
                         'rpcsecret': secrets.token_hex(32)})
    endpoint = 'lab-s3.gitlab.svc.cluster.local:3900'
    ensure('lab-object-storage', {
        'connection': '\n'.join([
            'provider: AWS', 'region: us-east-1',
            f'aws_access_key_id: {s3["accesskey"]}',
            f'aws_secret_access_key: {s3["secretkey"]}',
            'aws_signature_version: 4', f'endpoint: http://{endpoint}',
            'path_style: true', '',
        ]),
        's3cfg': '\n'.join([
            '[default]', f'access_key = {s3["accesskey"]}',
            f'secret_key = {s3["secretkey"]}', f'host_base = {endpoint}',
            f'host_bucket = {endpoint}', 'use_https = False',
            'signature_v2 = False', 'bucket_location = us-east-1', '',
        ]),
    })
