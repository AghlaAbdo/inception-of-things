#!/usr/bin/env python3
"""Bootstrap or commit a version in local GitLab. Short-lived PATs stay in memory."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'root/iot-playground'
API = 'http://127.0.0.1/api/v4'
CONTEXT = os.environ.get('CONTEXT', 'k3d-' + os.environ.get('CLUSTER_NAME', 'iot-bonus-helm'))
# All requests are to this VM's local lab, even when a shell has proxy variables.
HTTP = build_opener(ProxyHandler({}))


def token():
    # No shell interpolation or command-line credentials. runner receives Ruby on stdin.
    script = '''
user = User.find_by_username!('root')
token = user.personal_access_tokens.create!(name: 'iot-bonus-automation', scopes: ['api'], expires_at: Date.tomorrow)
token.set_token(SecureRandom.hex(32))
token.save!
puts "IOT_TOKEN=#{token.token}"
'''
    result = subprocess.run([
        'kubectl', '--context', CONTEXT, '-n', 'gitlab', 'exec', '-i',
        'deployment/gitlab-toolbox', '--', 'gitlab-rails', 'runner', '-',
    ], input=script, capture_output=True, text=True, check=True)
    found = re.search(r'^IOT_TOKEN=([a-f0-9]+)$', result.stdout, re.MULTILINE)
    if not found:
        raise RuntimeError('GitLab did not return the temporary automation token.')
    return found.group(1)


def request(path, method='GET', data=None, credential=None):
    headers = {'Host': 'gitlab.iot.test', 'Content-Type': 'application/json'}
    if credential:
        headers['PRIVATE-TOKEN'] = credential
    req = Request(API + path, headers=headers, method=method,
                  data=json.dumps(data).encode() if data is not None else None)
    with HTTP.open(req, timeout=60) as response:
        body = response.read()
        return json.loads(body) if body else None


def wait_ready():
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        try:
            with HTTP.open(Request('http://127.0.0.1/-/readiness',
                                 headers={'Host': 'gitlab.iot.test'}), timeout=10) as response:
                if response.status == 200:
                    return
        except (HTTPError, URLError, TimeoutError):
            pass
        time.sleep(5)
    raise RuntimeError('GitLab readiness timed out. Check ingress, pods and localhost port 80.')


def project(credential, create=False):
    try:
        return request('/projects/' + quote(PROJECT, safe=''), credential=credential)
    except HTTPError as exc:
        if exc.code != 404 or not create:
            raise
    return request('/projects', 'POST', {
        'name': 'iot-playground', 'path': 'iot-playground',
        'visibility': 'public', 'initialize_with_readme': False,
        'default_branch': 'main',
    }, credential)


def seed(credential):
    repo = project(credential, create=True)
    prefix = f'/projects/{repo["id"]}'
    if repo.get('visibility') != 'public':
        raise RuntimeError('Existing root/iot-playground must be public for anonymous Argo CD access.')
    # A rerun must never reset an evaluator's v2 commit back to v1.
    try:
        request(prefix + '/repository/branches/main', credential=credential)
        print('Existing main branch retained; no repository files overwritten.')
        return
    except HTTPError as exc:
        if exc.code != 404:
            raise
    actions = [{'action': 'create', 'file_path': 'app/' + file.name,
                'content': file.read_text()}
               for file in sorted((ROOT / 'confs' / 'app').glob('*.yaml'))]
    result = request(prefix + '/repository/commits', 'POST', {
        'branch': 'main', 'commit_message': 'Deploy playground v1 from local GitLab',
        'actions': actions,
    }, credential)
    print('Seeded local GitLab commit ' + result['short_id'])


def set_version(credential, version):
    repo = project(credential)
    prefix = f'/projects/{repo["id"]}'
    file = request(prefix + '/repository/files/app%2Fdeployment.yaml?ref=main',
                   credential=credential)
    content = base64.b64decode(file['content']).decode()
    updated, count = re.subn(r'(image:\s*wil42/playground:)v[12]\b',
                             lambda match: match.group(1) + version, content)
    if count != 1:
        raise RuntimeError('Expected exactly one wil42/playground v1/v2 image in the GitLab manifest.')
    if content == updated:
        print(f'GitLab already specifies {version}.')
        return
    result = request(prefix + '/repository/commits', 'POST', {
        'branch': 'main', 'commit_message': f'Deploy playground {version}',
        'actions': [{'action': 'update', 'file_path': 'app/deployment.yaml',
                     'content': updated, 'last_commit_id': file['last_commit_id']}],
    }, credential)
    print(f'Committed {version} in local GitLab: {result["short_id"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['seed', 'version'])
    parser.add_argument('version', nargs='?', choices=['v1', 'v2'])
    args = parser.parse_args()
    if args.action == 'version' and args.version is None:
        parser.error('version requires v1 or v2')
    wait_ready()
    credential = token()
    try:
        if args.action == 'seed':
            seed(credential)
        else:
            set_version(credential, args.version)
    finally:
        request('/personal_access_tokens/self', 'DELETE', credential=credential)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, HTTPError, URLError, subprocess.CalledProcessError) as exc:
        # Never echo captured Rails output: it may contain the temporary token.
        print(f'GitLab automation failed: {exc}', file=sys.stderr)
        sys.exit(1)
