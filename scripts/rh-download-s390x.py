#!/usr/bin/env python3
"""
Red Hat Downloads Portal - Automated bulk downloader for RHEL 9 s390x packages.

Uses a headless browser (Playwright) to authenticate via SSO and extract
all package download URLs from the portal, then downloads them with curl.

Prerequisites:
    pip install playwright requests
    playwright install chromium

Usage:
    export RH_USER="your-redhat-username"
    export RH_PASS="your-redhat-password"
    python3 rh-download-s390x.py [--dest ./rhel9-s390x] [--dry-run]
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

PORTAL_URL = (
    "https://access.redhat.com/downloads/content/72/ver=/rhel---9/9.6/s390x/packages"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Download RHEL 9 s390x packages from Red Hat portal")
    p.add_argument("--dest", default="./rhel9-s390x", help="Destination directory (default: ./rhel9-s390x)")
    p.add_argument("--dry-run", action="store_true", help="List files without downloading")
    p.add_argument("--filter", default="", help="Only download files whose name contains this string")
    p.add_argument("--user", default=os.environ.get("RH_USER", ""), help="Red Hat username (or set RH_USER env var)")
    p.add_argument("--password", default=os.environ.get("RH_PASS", ""), help="Red Hat password (or set RH_PASS env var)")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Browser session helpers
# ---------------------------------------------------------------------------

def login_and_get_session(user: str, password: str, target_url: str):
    """
    Launch a headless Chromium browser, log in via Red Hat SSO,
    navigate to target_url, and return:
      - cookies  (list of dicts for requests / curl)
      - page_content (rendered HTML of the packages page)
    """
    try:
        from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
    except ImportError:
        print("ERROR: playwright is not installed.")
        print("Run:  pip install playwright && playwright install chromium")
        sys.exit(1)

    print("[*] Launching headless browser...")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        ctx = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
            )
        )
        page = ctx.new_page()

        # Intercept XHR/fetch calls made by the SPA so we can capture the
        # underlying JSON API responses directly.
        api_responses = {}

        def on_response(response):
            url = response.url
            if "access.redhat.com" in url and response.status == 200:
                ct = response.headers.get("content-type", "")
                if "json" in ct:
                    try:
                        api_responses[url] = response.json()
                    except Exception:
                        pass

        page.on("response", on_response)

        # --- Navigate to the portal (will redirect to SSO) ---
        print(f"[*] Navigating to {target_url}")
        page.goto(target_url, wait_until="domcontentloaded", timeout=60_000)

        # --- Fill in SSO login form ---
        # Red Hat SSO shows username first, then password on next screen
        try:
            page.wait_for_selector("#username", timeout=20_000)
            print("[*] Entering username...")
            page.fill("#username", user)
            page.click("#login-show-step2")  # "Next" button on newer SSO
        except PWTimeout:
            # Older single-form SSO
            page.fill("#username", user)

        try:
            page.wait_for_selector("#password", timeout=15_000)
            print("[*] Entering password...")
            page.fill("#password", password)
            page.click("#kc-login")
        except PWTimeout:
            print("ERROR: Could not find password field. Check your credentials or SSO flow.")
            browser.close()
            sys.exit(1)

        # --- Wait for the downloads page to fully load (SPA renders async) ---
        print("[*] Waiting for packages page to render...")
        try:
            # Wait for at least one download link to appear
            page.wait_for_selector("a[href*='download']", timeout=60_000)
        except PWTimeout:
            print("WARNING: Timed out waiting for download links. Proceeding with what we have.")

        # Give the SPA a moment to finish all API calls
        time.sleep(3)

        html = page.content()
        cookies = ctx.cookies()
        browser.close()

    return cookies, html, api_responses


# ---------------------------------------------------------------------------
# Link extraction
# ---------------------------------------------------------------------------

def extract_download_links(html: str, api_responses: dict, name_filter: str) -> list[dict]:
    """
    Extract download links from either:
      1. Intercepted JSON API responses (preferred — structured data)
      2. Raw anchor tags in rendered HTML (fallback)
    Returns list of {name, url, size} dicts.
    """
    import re

    links = []
    seen = set()

    # --- Strategy 1: parse intercepted JSON API responses ---
    for url, data in api_responses.items():
        if not isinstance(data, (dict, list)):
            continue
        # Flatten top-level list or body list
        items = data if isinstance(data, list) else data.get("body", data.get("files", data.get("packages", [])))
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict):
                continue
            dl_url = item.get("downloadHref") or item.get("url") or item.get("href") or ""
            name = item.get("label") or item.get("name") or item.get("filename") or ""
            size = item.get("size") or item.get("fileSize") or ""
            if dl_url and dl_url not in seen:
                if name_filter.lower() in name.lower() or name_filter.lower() in dl_url.lower():
                    links.append({"name": name, "url": dl_url, "size": size})
                    seen.add(dl_url)

    # --- Strategy 2: scrape rendered HTML anchor tags ---
    if not links:
        pattern = re.compile(
            r'href="(https://[^"]*(?:download|cdn-[a-z0-9]+\.redhat\.com)[^"]*)"',
            re.IGNORECASE
        )
        for match in pattern.finditer(html):
            dl_url = match.group(1)
            if dl_url in seen:
                continue
            name = dl_url.split("/")[-1].split("?")[0] or dl_url
            if name_filter.lower() in name.lower() or name_filter.lower() in dl_url.lower():
                links.append({"name": name, "url": dl_url, "size": ""})
                seen.add(dl_url)

    return links


# ---------------------------------------------------------------------------
# Downloader
# ---------------------------------------------------------------------------

def download_file(url: str, dest_path: Path, cookies: list[dict]) -> bool:
    """Download a single file using curl with session cookies."""
    cookie_str = "; ".join(f"{c['name']}={c['value']}" for c in cookies)
    cmd = [
        "curl",
        "-L",                       # follow redirects
        "--fail",                   # fail on HTTP errors
        "--silent",
        "--show-error",
        "--progress-bar",
        "-b", cookie_str,
        "-o", str(dest_path),
        url,
    ]
    result = subprocess.run(cmd)
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    if not args.user or not args.password:
        print("ERROR: Red Hat credentials required.")
        print("  Set RH_USER and RH_PASS environment variables, or use --user / --password")
        sys.exit(1)

    dest = Path(args.dest)
    if not args.dry_run:
        dest.mkdir(parents=True, exist_ok=True)

    # Authenticate and load the page
    cookies, html, api_responses = login_and_get_session(args.user, args.password, PORTAL_URL)

    print(f"[*] Captured {len(api_responses)} API responses from the SPA")

    # Extract download links
    links = extract_download_links(html, api_responses, args.filter)

    if not links:
        print("\nERROR: No download links found.")
        print("Possible causes:")
        print("  - Login failed (check credentials)")
        print("  - Page structure changed")
        print("  - Subscription does not include this content")
        print("\nSaving debug HTML to /tmp/rh_debug.html for inspection")
        Path("/tmp/rh_debug.html").write_text(html)
        if api_responses:
            print("\nIntercepted API responses:")
            for url in api_responses:
                print(f"  {url}")
        sys.exit(1)

    print(f"\n[*] Found {len(links)} files to download")
    print(f"[*] Destination: {dest.resolve()}\n")

    # Print manifest
    for i, item in enumerate(links, 1):
        size_str = f"  ({item['size']})" if item["size"] else ""
        print(f"  [{i:3d}] {item['name'] or item['url']}{size_str}")

    if args.dry_run:
        print("\n[DRY RUN] No files downloaded.")
        return

    print()
    failed = []
    for i, item in enumerate(links, 1):
        name = item["name"] or urlparse(item["url"]).path.split("/")[-1] or f"file_{i}"
        # Sanitise filename
        safe_name = "".join(c for c in name if c.isalnum() or c in "._- ").strip()
        dest_path = dest / safe_name

        if dest_path.exists():
            print(f"  [SKIP] {safe_name} (already exists)")
            continue

        print(f"  [{i}/{len(links)}] Downloading {safe_name}...")
        ok = download_file(item["url"], dest_path, cookies)
        if not ok:
            print(f"  [FAIL] {safe_name}")
            failed.append(item)

    print(f"\n[*] Done. {len(links) - len(failed)}/{len(links)} files downloaded to {dest.resolve()}")
    if failed:
        print(f"[!] {len(failed)} failed downloads:")
        for f in failed:
            print(f"    {f['url']}")


if __name__ == "__main__":
    main()
