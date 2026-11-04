#!/usr/bin/env python3
"""GitHub settings that Terraform's github provider cannot manage: GitHub Apps from their manifests, and a read-only check.

  github-app.py create <app>            Register the App from github/apps/<app>.json (GitHub's manifest flow: one click on
                                        "Create GitHub App" in the browser), write its private key and client ID where
                                        github/apps/destinations.json says, open its install page, then verify the
                                        installation covers exactly the repositories listed there.
  github-app.py set-key <app> <key> <pem>  Write a private key (a second key, or a rotated one) to destination <key> of the App
                                        and delete the .pem file. Keys are generated on the App's page; GitHub has no API for it.
  github-app.py check [--with-app-keys] Read-only check of every setting of the README table "Không quản" that has an API.
                                        Local key files (backend/.env) are left alone unless --with-app-keys: then their
                                        variables are checked and the Apps whose key is local sign in to read their installation.
  github-app.py selftest                Offline checks of the manifests, destinations and helpers (make check runs it).

Private keys are never printed. Run by the person who owns the account (gh signed in with scope repo), never by CI.
"""
import argparse
import base64
import html
import http.server
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

GITHUB = pathlib.Path(__file__).resolve().parent.parent  # infra/github
WORKSPACE = GITHUB.parent.parent  # the folder holding the clones: backend/, infra/, ...
APPS = GITHUB / "apps"
KEYS = GITHUB / ".keys"  # git-ignored: a key waiting for its environment
OWNER = "anhnvcoder"
API = "https://api.github.com"
# Same set as local.repositories of github/repositories.tf (selftest compares the two).
REPOSITORIES = ["svp-backend", "svp-frontend", "svp-gitops", "svp-infra", "svp-labs", ".github"]
# Images the stg and prd overlays of svp-gitops pull anonymously: their GHCR packages must be public.
PUBLIC_PACKAGES = [f"svp-backend/{s}" for s in
                   ("gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker")] + ["svp-frontend/web"]
CODEQL_DEFAULT_SETUP = ["svp-backend", "svp-frontend"]
MANIFEST_KEYS = {"name", "url", "hook_attributes", "redirect_url", "callback_urls", "setup_url", "description", "public",
                 "default_events", "default_permissions", "request_oauth_on_install", "setup_on_update"}


def die(message):
    sys.stderr.write(f"FAIL  {message}\n")
    sys.exit(1)


def load_app(name):
    path = APPS / f"{name}.json"
    if not path.is_file():
        die(f"no manifest {path.relative_to(GITHUB.parent)}; apps: {', '.join(sorted(load_destinations()))}")
    return json.loads(path.read_text()), load_destinations()[name]


def load_destinations():
    return json.loads((APPS / "destinations.json").read_text())


def gh(*args, stdin=None):
    """Run gh; return stdout. Fails loudly: every call here is part of a setting the person asked to write or check."""
    proc = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"gh {' '.join(args[:3])}…: {proc.stderr.strip()}")
    return proc.stdout


def http_json(method, url, token=None, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as err:
        die(f"{method} {url}: HTTP {err.code} {err.read()[:300].decode(errors='replace')}")


# --- writing keys -----------------------------------------------------------------------------------------------------

def environment_exists(repo, environment):
    return subprocess.run(["gh", "api", f"repos/{OWNER}/{repo}/environments/{environment}"], capture_output=True).returncode == 0


def write_key(dest, pem, app_id=None, app=None, key=None):
    if dest["type"] == "environment-secret":
        if not environment_exists(dest["repo"], dest["environment"]):
            # Terraform creates the environment, and Terraform needs the App's client ID first (a new account): keep the key
            # in a git-ignored file until then.
            KEYS.mkdir(mode=0o700, exist_ok=True)
            held = KEYS / f"{app}-{key}.pem"
            held.write_text(pem)
            os.chmod(held, 0o600)
            print(f"next  environment {dest['environment']} of {dest['repo']} does not exist yet: key kept in "
                  f"{held.relative_to(GITHUB.parent)}; after plan and apply of github/, run "
                  f"make github-app-key APP={app} KEY={key} PEM={held.relative_to(GITHUB.parent)}")
            return
        gh("secret", "set", dest["name"], "--env", dest["environment"], "--repo", f"{OWNER}/{dest['repo']}", stdin=pem)
        print(f"ok    private key → secret {dest['name']} of environment {dest['environment']} of {dest['repo']}")
    elif dest["type"] == "dotenv":
        values = {"PRIVATE_KEY_B64": base64.b64encode(pem.encode()).decode()}
        if app_id is not None:
            values["APP_ID"] = str(app_id)
        set_dotenv(WORKSPACE / dest["file"], dest["prefix"], values)
        print(f"ok    private key{' and App ID' if app_id is not None else ''} → {dest['file']} ({dest['prefix']}_*)")
    else:
        die(f"unknown key destination type {dest['type']}")


def set_dotenv(path, prefix, values):
    """Replace or append PREFIX_NAME=value lines; the file stays mode 600 and no other line changes."""
    lines = path.read_text().splitlines() if path.exists() else []
    names = {f"{prefix}_{k}" for k in values}
    kept = [line for line in lines if line.split("=", 1)[0] not in names]
    kept += [f"{prefix}_{k}={v}" for k, v in values.items()]
    path.write_text("\n".join(kept) + "\n")
    os.chmod(path, 0o600)


def set_tfvar(name, value):
    path = GITHUB / "github.auto.tfvars"
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [line for line in lines if not re.match(rf"\s*{re.escape(name)}\s*=", line)] + [f'{name} = "{value}"']
    path.write_text("\n".join(lines) + "\n")
    print(f"ok    client ID → {name} in github/github.auto.tfvars (then plan and apply github/: the environment variable follows)")


# --- signing in as the App (RS256 JWT through openssl: the standard library has no RSA) --------------------------------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id, pem):
    now = int(time.time())
    signing_input = f"{b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT'}).encode())}." \
                    f"{b64url(json.dumps({'iat': now - 60, 'exp': now + 540, 'iss': str(app_id)}).encode())}"
    fd, keyfile = tempfile.mkstemp(suffix=".pem")
    try:
        os.write(fd, pem.encode())
        os.close(fd)
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", keyfile], input=signing_input.encode(),
                             capture_output=True, check=True).stdout
    finally:
        os.remove(keyfile)
    return f"{signing_input}.{b64url(sig)}"


def installed_repositories(app_id, pem):
    """(installation id, sorted repository names) of the App's installation on OWNER, or (None, []) when not installed."""
    token = app_jwt(app_id, pem)
    inst = [i for i in http_json("GET", f"{API}/app/installations", token) if i["account"]["login"] == OWNER]
    if not inst:
        return None, []
    access = http_json("POST", f"{API}/app/installations/{inst[0]['id']}/access_tokens", token)["token"]
    repos = http_json("GET", f"{API}/installation/repositories?per_page=100", access)["repositories"]
    return inst[0]["id"], sorted(r["name"] for r in repos)


# --- create -----------------------------------------------------------------------------------------------------------

def manifest_form(manifest, redirect_url, state):
    body = dict(manifest, redirect_url=redirect_url)
    return ("<!doctype html><meta charset=utf-8><title>Register GitHub App</title>"
            f'<form id=f method=post action="https://github.com/settings/apps/new?state={html.escape(state)}">'
            f'<input type=hidden name=manifest value="{html.escape(json.dumps(body))}"></form>'
            "<script>document.getElementById('f').submit()</script>")


class ManifestServer:
    """Loopback server: / posts the manifest to GitHub, /callback takes the code GitHub sends back with the right state."""

    def __init__(self, manifest):
        self.state, self.code = secrets.token_urlsafe(24), None
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 (http.server's name)
                url = urllib.parse.urlparse(self.path)
                query = urllib.parse.parse_qs(url.query)
                if url.path == "/":
                    page = manifest_form(manifest, f"{outer.url}callback", outer.state)
                elif url.path == "/callback" and query.get("state") == [outer.state] and query.get("code"):
                    outer.code = query["code"][0]
                    page = "<!doctype html><meta charset=utf-8>App registered. Back to the terminal."
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(page.encode())

            def log_message(self, *args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def wait_for_code(manifest, timeout=900):
    """Serve the manifest form on loopback, open it, and return the code GitHub sends back to the redirect URL."""
    srv = ManifestServer(manifest)
    print(f"open  {srv.url} (opening it now): check the name and permissions, then Create GitHub App")
    webbrowser.open(srv.url)
    deadline = time.time() + timeout
    while srv.code is None and time.time() < deadline:
        time.sleep(0.5)
    srv.close()
    if srv.code is None:
        die(f"no answer from GitHub in {timeout // 60} minutes; run create again")
    return srv.code


def create(name, code=None):
    manifest, dest = load_app(name)
    code = code or wait_for_code(manifest)
    app = http_json("POST", f"{API}/app-manifests/{code}/conversions")  # the one-time code is the credential
    pem, app_id, slug = app["pem"], app["id"], app["slug"]
    print(f"ok    App {slug}: App ID {app_id}, client ID {app['client_id']} (neither is secret)")
    first = next(iter(dest["keys"]))
    write_key(dest["keys"][first], pem, app_id, name, first)
    if "client_id_tfvar" in dest:
        set_tfvar(dest["client_id_tfvar"], app["client_id"])
    if len(dest["keys"]) > 1:
        others = ", ".join(k for k in dest["keys"] if k != first)
        print(f"next  key {others}: generate a second key on https://github.com/settings/apps/{slug} (Private keys), then"
              f" github-app.py set-key {name} <{others}> <file.pem>")
    url = f"https://github.com/apps/{slug}/installations/new"
    print(f"next  install on {', '.join(dest['install_on'])} only (Only select repositories): {url}")
    webbrowser.open(url)
    input("      press Enter once the App is installed… ")
    inst_id, repos = installed_repositories(app_id, pem)
    if repos != sorted(dest["install_on"]):
        die(f"installation {inst_id} covers {repos or 'nothing'}, want {sorted(dest['install_on'])}: fix it on "
            f"https://github.com/settings/installations, then run check --with-app-keys")
    for key in dest["keys"].values():
        if key["type"] == "dotenv":
            set_dotenv(WORKSPACE / key["file"], key["prefix"], {"INSTALLATION_ID": str(inst_id)})
    print(f"ok    installation {inst_id} covers exactly {', '.join(repos)}")


def set_key(name, key, pem_path):
    _, dest = load_app(name)
    if key not in dest["keys"]:
        die(f"{name} has keys {', '.join(dest['keys'])}, not {key}")
    path = pathlib.Path(pem_path).expanduser()
    pem = path.read_text()
    if not pem.startswith("-----BEGIN ") or "PRIVATE KEY-----" not in pem:
        die(f"{path} is not a PEM private key")
    if dest["keys"][key]["type"] == "environment-secret" and not environment_exists(dest["keys"][key]["repo"], dest["keys"][key]["environment"]):
        die(f"environment {dest['keys'][key]['environment']} of {dest['keys'][key]['repo']} does not exist: plan and apply github/ first")
    write_key(dest["keys"][key], pem, app=name, key=key)
    path.unlink()
    print(f"ok    {path} deleted; on the App's page delete the key it replaces, if any")


# --- check ------------------------------------------------------------------------------------------------------------

def check(with_app_keys):
    bad = []

    def expect(label, got, want):
        ok = got == want
        print(f"{'ok  ' if ok else 'FAIL'}  {label}: {got}" + ("" if ok else f" (want {want})"))
        if not ok:
            bad.append(label)

    def api(path, jq):
        proc = subprocess.run(["gh", "api", path, "--jq", jq], capture_output=True, text=True)
        return proc.stdout.strip() if proc.returncode == 0 else f"error: {proc.stderr.strip()[:120]}"

    for repo in REPOSITORIES:
        r = f"repos/{OWNER}/{repo}"
        expect(f"{repo} private vulnerability reporting", api(f"{r}/private-vulnerability-reporting", ".enabled"), "true")
        expect(f"{repo} fork pull request approval",
               api(f"{r}/actions/permissions/fork-pr-contributor-approval", ".approval_policy"), "all_external_contributors")
        expect(f"{repo} default branch", api(r, ".default_branch"), "main")
        expect(f"{repo} Dependabot security updates", api(r, ".security_and_analysis.dependabot_security_updates.status"),
               "disabled")
        for rid in api(f"{r}/rulesets", ".[].id").split():
            got = api(f"{r}/rulesets/{rid}",
                      '[.rules[]|select(.type=="pull_request")|.parameters.require_extra_approval_for_unattributed_changes]|first')
            if got not in ("", "null"):
                expect(f"{repo} ruleset {rid} extra approval for unattributed changes", got, "true")
    for repo in CODEQL_DEFAULT_SETUP:
        expect(f"{repo} CodeQL default setup", api(f"repos/{OWNER}/{repo}/code-scanning/default-setup", ".state"), "configured")
    for name, dest in load_destinations().items():
        for key in dest["keys"].values():
            if key["type"] == "environment-secret":
                names = api(f"repos/{OWNER}/{key['repo']}/environments/{key['environment']}/secrets", ".secrets[].name").split()
                expect(f"{name} key in {key['repo']} {key['environment']}", key["name"] in names, True)
            elif key["type"] == "dotenv":
                if not with_app_keys:  # a local secret file: read only when its owner asks (make github-check WITH_APP_KEYS=1)
                    print(f"skip  {name} key in {key['file']}: run with --with-app-keys (WITH_APP_KEYS=1) to read it")
                    continue
                env = WORKSPACE / key["file"]
                have = {line.split("=", 1)[0] for line in env.read_text().splitlines()} if env.exists() else set()
                want = {f"{key['prefix']}_{k}" for k in ("APP_ID", "INSTALLATION_ID", "PRIVATE_KEY_B64")}
                expect(f"{name} variables in {key['file']}", sorted(want - have) or "all present", "all present")
                if not (want - have):
                    values = dict(line.split("=", 1) for line in env.read_text().splitlines() if line.startswith(key["prefix"]))
                    pem = base64.b64decode(values[f"{key['prefix']}_PRIVATE_KEY_B64"]).decode()
                    inst_id, repos = installed_repositories(values[f"{key['prefix']}_APP_ID"], pem)
                    expect(f"{name} installation repositories", repos, sorted(dest["install_on"]))
                    expect(f"{name} installation ID in {key['file']}", values[f"{key['prefix']}_INSTALLATION_ID"], str(inst_id))
    for pkg in PUBLIC_PACKAGES:
        url = f"https://ghcr.io/token?scope=repository:{OWNER}/{pkg}:pull"
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                public = bool(json.loads(resp.read()).get("token"))
        except urllib.error.HTTPError:
            public = False
        expect(f"package ghcr.io/{OWNER}/{pkg} pulls anonymously", public, True)
    print("Apps and their installations other than those with a local key: check by hand (README, table 'Không quản').")
    if bad:
        die(f"{len(bad)} setting(s) differ: {', '.join(bad)}")
    print("ok    every setting matches")


# --- selftest ---------------------------------------------------------------------------------------------------------

def selftest():
    dests = load_destinations()
    manifests = sorted(p.stem for p in APPS.glob("*.json") if p.name != "destinations.json")
    assert manifests == sorted(dests), f"manifests {manifests} and destinations {sorted(dests)} differ"
    tf = (GITHUB / "repositories.tf").read_text()
    block = tf[tf.index("repositories = {"):]
    tf_repos = re.findall(r'^\s{4}"?([.\w-]+)"?\s*=\s*\{', block, re.M)
    assert sorted(tf_repos) == sorted(REPOSITORIES), f"REPOSITORIES {REPOSITORIES} differ from repositories.tf {tf_repos}"
    for name in manifests:
        manifest, dest = load_app(name)
        assert set(manifest) <= MANIFEST_KEYS, f"{name}: keys outside GitHub's manifest: {set(manifest) - MANIFEST_KEYS}"
        assert manifest["name"] == name and manifest["public"] is False, f"{name}: name or public"
        assert manifest["hook_attributes"]["active"] is False and manifest["default_events"] == [], f"{name}: webhook on"
        assert manifest["default_permissions"].get("metadata") == "read", f"{name}: metadata"
        assert set(manifest["default_permissions"].values()) <= {"read", "write"}, f"{name}: permission values"
        assert dest["install_on"] and set(dest["install_on"]) <= set(REPOSITORIES), f"{name}: install_on"
        for key in dest["keys"].values():
            assert key["type"] in ("environment-secret", "dotenv"), f"{name}: key type"
        form = manifest_form(manifest, "http://127.0.0.1:1/callback", "s<t")
        assert "s&lt;t" in form and "&quot;" in form and '"' + name not in form, f"{name}: form escaping"
    with tempfile.TemporaryDirectory() as tmp:
        env = pathlib.Path(tmp) / ".env"
        env.write_text("A=1\nP_APP_ID=old\nB=2\n")
        set_dotenv(env, "P", {"APP_ID": "7", "PRIVATE_KEY_B64": "eA=="})
        assert env.read_text() == "A=1\nB=2\nP_APP_ID=7\nP_PRIVATE_KEY_B64=eA==\n", env.read_text()
        assert oct(env.stat().st_mode & 0o777) == "0o600"
    assert b64url(b"\xfb\xff") == "-_8"
    print(f"ok    selftest: {len(manifests)} manifests, destinations, repository list, form escaping, .env rewrite")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("app")
    c.add_argument("--code", help="the code of the redirect URL, when the browser could not reach the loopback page")
    k = sub.add_parser("set-key")
    k.add_argument("app")
    k.add_argument("key")
    k.add_argument("pem")
    ch = sub.add_parser("check")
    ch.add_argument("--with-app-keys", action="store_true")
    sub.add_parser("selftest")
    args = parser.parse_args()
    if args.cmd == "create":
        create(args.app, args.code)
    elif args.cmd == "set-key":
        set_key(args.app, args.key, args.pem)
    elif args.cmd == "check":
        check(args.with_app_keys)
    else:
        selftest()


if __name__ == "__main__":
    main()
