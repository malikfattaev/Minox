#!/usr/bin/env python3
"""Разовый вход Minox в аккаунт Claude.

Заводит Minox собственную пару токенов в связке ключей. Токены Claude Code
не трогаются вообще: их refresh-токен при обновлении ротируется, и второй
процесс, крутящий ту же запись, рано или поздно разлогинил бы тебя.

Запуск: python3 scripts/claude-auth.py
"""
import base64, getpass, hashlib, json, os, secrets, subprocess, sys, time, urllib.parse

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
# Клиент зарегистрирован с фиксированным набором прав: урезанный запрос
# сервер отклоняет как "Invalid request format". Нужен нам только user:profile.
SCOPES = ("org:create_api_key user:profile user:inference "
          "user:sessions:claude_code user:mcp_servers user:file_upload")
KEYCHAIN_SERVICE = "Minox-claude-oauth"
# Cloudflare перед platform.claude.com отбивает запросы без внятного User-Agent.
USER_AGENT = "claude-cli/2.1.257 (external, cli)"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def post_json(url: str, payload: dict) -> dict:
    result = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", url,
         "-H", "Content-Type: application/json",
         "-H", f"User-Agent: {USER_AGENT}",
         "--data-binary", json.dumps(payload), "--max-time", "30"],
        capture_output=True, text=True,
    )
    body, _, code = result.stdout.rpartition("\n")
    if code != "200":
        sys.exit(f"обмен не удался: HTTP {code}\n{body[:400]}")
    return json.loads(body)


def store(tokens: dict) -> None:
    blob = json.dumps(tokens)
    rc = subprocess.run(
        ["security", "add-generic-password", "-U",
         "-s", KEYCHAIN_SERVICE, "-a", os.environ.get("USER", ""), "-w", blob],
        capture_output=True, text=True,
    ).returncode
    if rc != 0:
        sys.exit("не удалось записать в связку ключей")


def main() -> None:
    verifier = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    # Сервер проверяет формат state: 16 байт он отклоняет как
    # "Invalid request format", Claude Code шлёт ровно 32.
    state = b64url(secrets.token_bytes(32))

    url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "code": "true",
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })

    print("Открываю браузер. Подтверди доступ, потом скопируй показанный код.\n")
    print(url, "\n")
    subprocess.run(["open", url])

    raw = getpass.getpass("Вставь код (ввод скрыт) и нажми Enter: ").strip()
    if not raw:
        sys.exit("код не введён")
    code, _, returned_state = raw.partition("#")

    tokens = post_json(TOKEN_URL, {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "client_id": CLIENT_ID,
        "code_verifier": verifier,
        "state": returned_state or state,
    })

    store({
        "accessToken": tokens["access_token"],
        "refreshToken": tokens["refresh_token"],
        "expiresAt": int((time.time() + tokens.get("expires_in", 28800)) * 1000),
        "scopes": tokens.get("scope", SCOPES),
    })
    print(f"\nГотово. Токен записан в связку ключей как «{KEYCHAIN_SERVICE}».")
    print("Права:", tokens.get("scope", SCOPES))
    print("Перезапусти Minox.")


if __name__ == "__main__":
    main()
