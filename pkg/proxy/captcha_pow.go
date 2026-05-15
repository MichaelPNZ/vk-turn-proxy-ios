package proxy

import (
	"compress/flate"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	mathrand "math/rand"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/andybalholm/brotli"
	"github.com/klauspost/compress/zstd"
)

// captchaPowProfile stores the browser profile for the current PoW session.
var captchaPowProfile BrowserProfile

// VKBrowserProfile is a captured-from-real-browser fingerprint reused in
// the auto-PoW solver to evade VK's bot detection. The Swift main app's
// CaptchaWKWebView intercepts captchaNotRobot.componentDone request bodies
// (where a real browser sends VK its computed device + browser_fp) and
// persists them to App Group vk_profile.json. Subsequent solveCaptchaPoW
// calls — in either main app or extension process — load this file and
// substitute the captured values for the generated ones, dramatically
// improving the auto-solve success rate (observed 6% with generated
// browser_fp, vpn.wifi.0.log 2026-05-08; expected to climb sharply with
// real captured values per Moroka8 PR #162 commit b9642c6).
//
// The captured Device is the form-encoded value from VK's request body
// (already URL-encoded JSON); BrowserFp is the encoded fingerprint
// string. Both go directly into our outgoing componentDone/check
// requests without re-encoding.
type VKBrowserProfile struct {
	Device    string  `json:"device"`
	BrowserFp string  `json:"browser_fp"`
	UserAgent string  `json:"user_agent"`
	// CapturedAt is unix seconds with sub-second fraction. Stored as
	// float64 because Swift writes TimeInterval (Double) and Go's
	// json.Unmarshal won't coerce a float into int64. Match Swift's
	// type to keep the round-trip lossless.
	CapturedAt float64 `json:"captured_at"`
}

// vkProfilePath holds the App Group container path to vk_profile.json.
// Set via SetVKProfilePath from bridge.go's wgSetLogFilePath. Read by
// loadSavedVKProfile on every solveCaptchaPoW call (no caching — the
// file is small, reading once per captcha attempt is negligible, and
// cache invalidation gets messy).
var vkProfilePath atomic.Value // string

// SetVKProfilePath records where vk_profile.json lives in the App Group
// container. Empty string disables loading (loadSavedVKProfile returns
// nil silently). Called once during bridge init for both main app and
// extension processes.
func SetVKProfilePath(p string) {
	vkProfilePath.Store(p)
}

// loadSavedVKProfile returns the captured profile if the file exists
// and parses cleanly, or nil otherwise. Missing file / parse error /
// empty fields all yield nil — caller falls back to generated values.
// Logs the load decision so production logs show whether the captured
// profile is being used on each PoW attempt.
func loadSavedVKProfile() *VKBrowserProfile {
	v := vkProfilePath.Load()
	if v == nil {
		return nil
	}
	path, _ := v.(string)
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		// ENOENT is normal (no captured profile yet); other errors
		// suggest something wrong with App Group container access.
		if !os.IsNotExist(err) {
			log.Printf("pow: vk_profile.json read failed: %v", err)
		}
		return nil
	}
	var p VKBrowserProfile
	if err := json.Unmarshal(data, &p); err != nil {
		log.Printf("pow: vk_profile.json parse failed: %v", err)
		return nil
	}
	if p.BrowserFp == "" || p.Device == "" {
		log.Printf("pow: vk_profile.json missing required fields (device=%dc, browser_fp=%dc)",
			len(p.Device), len(p.BrowserFp))
		return nil
	}
	return &p
}

// randomHex generates a random hex string of n bytes (2n hex chars).
var _ = randomHex

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		for i := range b {
			b[i] = byte(mathrand.Intn(256))
		}
	}
	return hex.EncodeToString(b)
}

// newSessionClient creates an HTTP client with a shared cookie jar.
//
// TLS fingerprint: HelloChrome_Auto (= HelloChrome_133 in uTLS v1.8.2),
// which is structurally identical to Safari iOS 17 ClientHello. Both
// browsers converged on the same modern TLS extensions (X25519MLKEM768,
// ECH, ALPS, Brotli compress_certificate, GREASE positions, extension
// shuffle, identical cipher list + supported_groups + signature
// algorithms). HelloIOS_Auto in v1.8.2 maps to HelloIOS_14, which is
// strictly older and DIFFERENT from real iOS 17 — switching to it
// would be a downgrade. So Chrome_Auto stays even for the Safari-UA
// captcha session: at the TLS layer there is no detectable difference
// between Chrome 133 and Safari iOS 17.
//
// Phase 4 of the 2026-05-15 PoW regression investigation briefly tried
// HelloIOS_Auto on the assumption that UA/TLS mismatch was the bot
// signal — empirically wrong; the previous session had already
// established TLS identity. Reverted in build 96.
func newSessionClient() *http.Client {
	jar, _ := cookiejar.New(nil)
	return &http.Client{
		Timeout:   20 * time.Second,
		Jar:       jar,
		Transport: newChromeTransport(),
	}
}

// newHTTPClient creates a fresh http.Client (no cookie jar) with Chrome TLS fingerprint.
func newHTTPClient() *http.Client {
	return &http.Client{
		Timeout:   20 * time.Second,
		Transport: newChromeTransport(),
	}
}

// solveCaptchaPoW attempts to solve a VK "Not Robot" captcha automatically
// using proof-of-work, without any user interaction.
//
// Returns (successToken, lastShowCaptchaType, err). lastShowCaptchaType is the
// last known hint from VK about what captcha type should be presented to the
// user — either from the API `captchaNotRobot.check` response or (when the
// checkbox check is skipped) from the HTML page's window.init payload. The
// caller (creds.go) uses it as a signal for retry/backoff decisions.
func solveCaptchaPoW(ctx context.Context, redirectURI, captchaSID, userAgent string) (string, string, error) {
	captchaPowProfile = profileForUA(userAgent)
	// If we have a captured browser profile (from WKWebView capture saved
	// to vk_profile.json), override the UA derived from the input userAgent
	// param. The captured UA is the one VK saw when computing the captured
	// browser_fp; sending a mismatched UA to validate that fp triggers BOT.
	// Before this override (2026-05-11) we sent UA=Chrome desktop while the
	// captured browser_fp was computed for Safari iOS Mobile — guaranteed
	// fingerprint inconsistency on every check.
	if saved := loadSavedVKProfile(); saved != nil && saved.UserAgent != "" {
		captchaPowProfile.UserAgent = saved.UserAgent
	}
	log.Printf("pow: attempting automatic captcha solve (UA: %s, platform: %s, Chrome/%d)",
		captchaPowProfile.UserAgent, captchaPowProfile.Platform, captchaPowProfile.ChromeVersion)

	parsed, err := url.Parse(redirectURI)
	if err != nil {
		return "", "", fmt.Errorf("parse redirect_uri: %w", err)
	}
	sessionToken := parsed.Query().Get("session_token")
	if sessionToken == "" {
		return "", "", fmt.Errorf("no session_token in redirect_uri")
	}

	// Single HTTP client with cookie jar for the entire captcha session.
	client := newSessionClient()
	defer client.CloseIdleConnections()

	// Random initial delay (1.5-2.5s) — HAR timing from real browser
	delay := time.Duration(1500+mathrand.Intn(1000)) * time.Millisecond
	select {
	case <-time.After(delay):
	case <-ctx.Done():
		return "", "", ctx.Err()
	}

	// Step 1: Fetch captcha page and extract PoW parameters + cookies + slider settings + JS bundle URL
	powInput, difficulty, scriptURL, htmlSettings, err := fetchPoW(ctx, client, redirectURI)
	if err != nil {
		return "", "", fmt.Errorf("fetch PoW: %w", err)
	}
	log.Printf("pow: input=%s difficulty=%d htmlSettings=%v scriptURL=%s", powInput, difficulty, htmlSettings != nil, scriptURL)

	// Phase 6: Pull the version-specific debug_info constant from the
	// captcha JS bundle. Falls back to hardcoded value if the bundle URL
	// wasn't extracted or if regex doesn't match the JS contents. Cache
	// is keyed on full scriptURL (versioned path) so VK rotating the
	// constant via a JS bump auto-invalidates.
	debugInfo := fetchAndCacheDebugInfo(ctx, client, scriptURL)

	// Log cookies received from page load (for debugging)
	if parsedURL, e := url.Parse("https://id.vk.ru"); e == nil {
		cookies := client.Jar.Cookies(parsedURL)
		log.Printf("pow: received %d cookies from page load", len(cookies))
	}
	if parsedURL, e := url.Parse("https://vk.ru"); e == nil {
		cookies := client.Jar.Cookies(parsedURL)
		log.Printf("pow: received %d cookies from vk.ru domain", len(cookies))
	}

	// Step 1.5: Generate adFp (random 21-char base64url) and fire mail.ru
	// tracking ping. Both pieces match what real Safari does on
	// not_robot_captcha page load via sync-loader.js. The ping return value
	// is empty (verified) so it's purely a Safari-mimicry signal; the adFp
	// is included in captchaNotRobot.check body where VK now requires it
	// to be present (since some VK update around 2026-05-08/09).
	adFp := getSessionAdFp()
	log.Printf("pow: using session adFp=%s for this PoW solve", adFp)
	fetchAdFpPing(ctx, client)

	// Step 2: Solve PoW (brute-force SHA-256)
	hash := solvePoW(powInput, difficulty)
	if hash == "" {
		return "", "", fmt.Errorf("PoW: no solution found within 10M iterations")
	}
	log.Printf("pow: solved hash=%s...%s", hash[:8], hash[len(hash)-8:])

	// Brief pause after PoW (simulate browser JS execution time)
	time.Sleep(time.Duration(200+mathrand.Intn(300)) * time.Millisecond)

	// Step 3: Call captchaNotRobot API sequence (using same client = same cookies)
	successToken, showType, err := callCaptchaNotRobotAPI(ctx, client, sessionToken, hash, adFp, debugInfo, htmlSettings)
	if err != nil {
		return "", showType, fmt.Errorf("captchaNotRobot API: %w", err)
	}

	log.Printf("pow: success! token=%d chars", len(successToken))
	return successToken, showType, nil
}

// debugInfoCache maps captcha-script URL → extracted debug_info hex
// constant. Per Moroka8/vk-turn-proxy commit 21cf9fa: the constant is
// versioned (path includes vkid/<version>/not_robot_captcha.js), VK
// rotates it when bumping the captcha JS bundle. Caching by full URL
// auto-invalidates on version change.
var debugInfoCache sync.Map

// debugInfoRegex extracts the constant fallback from the captcha JS:
//
//	debug_info: (window.vk?.brlefapmjnpg) || "a0ac4896...64hex..."
//
// or older: debug_info: "a0ac4896..."
//
// Captures the 64-hex string. If the JS structure changes the fallback
// extraction fails and we use the hardcoded constant from build 93 as
// last resort.
var debugInfoRegex = regexp.MustCompile(`debug_info:(?:[^"]*\|\|)?"([a-fA-F0-9]{64})"`)

// captchaJSRegex finds the not_robot_captcha.js script URL embedded in
// the captcha HTML page so we can fetch it and extract debug_info.
var captchaJSRegex = regexp.MustCompile(`src="(https://[^"]+not_robot_captcha[^"]+)"`)

// hardcodedDebugInfo is the build-93 fallback constant captured from
// Safari WKWebView 2026-05-15. Used when dynamic extraction fails.
const hardcodedDebugInfo = "a0ac4896e9b899f78d905fd37c5adb2b768aa955eb7b2a7bcba6ee2a44a96daf"

// fetchAndCacheDebugInfo GETs the captcha JS bundle, extracts the
// debug_info constant via debugInfoRegex, caches by script URL, and
// returns the extracted value. Returns hardcodedDebugInfo on any
// failure (regex miss, HTTP error, parse error) — the captcha attempt
// will still be made with the previously-canonical value rather than
// failing outright.
//
// Phase 6 of the 2026-05-15 PoW regression investigation: ports
// dynamic extraction from Moroka8 captcha v2. If VK rotates the
// constant in a future JS version (bumping the vkid/X.Y.Z path), we
// pick it up automatically; build 93's hardcoded value would have
// become stale.
func fetchAndCacheDebugInfo(ctx context.Context, client *http.Client, scriptURL string) string {
	if scriptURL == "" {
		return hardcodedDebugInfo
	}
	if cached, ok := debugInfoCache.Load(scriptURL); ok {
		return cached.(string)
	}
	req, err := http.NewRequestWithContext(ctx, "GET", scriptURL, nil)
	if err != nil {
		log.Printf("pow: debug_info fetch req-build failed (%v) — falling back to hardcoded constant", err)
		return hardcodedDebugInfo
	}
	req.Header.Set("User-Agent", captchaPowProfile.UserAgent)
	req.Header.Set("Accept", "text/javascript,*/*")
	req.Header.Set("Accept-Encoding", safariAcceptEncoding)
	req.Header.Set("Accept-Language", "en-GB,en;q=0.9")
	req.Header.Set("Referer", "https://id.vk.ru/")
	req.Header.Set("Sec-Fetch-Dest", "script")
	req.Header.Set("Sec-Fetch-Mode", "no-cors")
	req.Header.Set("Sec-Fetch-Site", "same-site")
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("pow: debug_info fetch failed (%v) — falling back to hardcoded constant", err)
		return hardcodedDebugInfo
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := readDecompressedBody(resp)
	if err != nil {
		log.Printf("pow: debug_info read body failed (%v) — falling back to hardcoded constant", err)
		return hardcodedDebugInfo
	}
	m := debugInfoRegex.FindSubmatch(body)
	if len(m) < 2 {
		log.Printf("pow: debug_info regex no match in JS (%d bytes) — falling back to hardcoded constant", len(body))
		return hardcodedDebugInfo
	}
	value := string(m[1])
	debugInfoCache.Store(scriptURL, value)
	log.Printf("pow: debug_info extracted from %s = %s (cached)", scriptURL, value)
	return value
}

// fetchPoW fetches the captcha HTML page and extracts PoW parameters.
// scriptURL is the captcha JS bundle URL (e.g. https://static.vk.ru/vkid/
// 1.1.1331/not_robot_captcha.js), used by fetchAndCacheDebugInfo to
// extract the version-specific debug_info constant. Empty if extraction
// fails (caller falls back to hardcodedDebugInfo).
func fetchPoW(ctx context.Context, client *http.Client, redirectURI string) (powInput string, difficulty int, scriptURL string, htmlSettings map[string]interface{}, err error) {
	req, err := http.NewRequestWithContext(ctx, "GET", redirectURI, nil)
	if err != nil {
		return "", 0, "", nil, err
	}
	// Headers calibrated for Safari iOS 17 mobile (see vkReq for full
	// rationale). For the document GET we keep navigate-mode Sec-Fetch
	// triplet plus Upgrade-Insecure-Requests. Removed: sec-ch-ua* (Chrome
	// only), DNT (Safari dropped). Changed: Accept stripped of Chrome-specific
	// image format preferences (Safari sends a simpler Accept), Accept-Language
	// → en-GB matching captured device.language.
	req.Header.Set("User-Agent", captchaPowProfile.UserAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Encoding", safariAcceptEncoding)
	req.Header.Set("Accept-Language", "en-GB,en;q=0.9")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Pragma", "no-cache")
	req.Header.Set("Priority", "u=0, i")
	req.Header.Set("Sec-Fetch-Dest", "document")
	req.Header.Set("Sec-Fetch-Mode", "navigate")
	req.Header.Set("Sec-Fetch-Site", "none")
	req.Header.Set("Sec-Fetch-User", "?1")
	req.Header.Set("Upgrade-Insecure-Requests", "1")

	resp, err := client.Do(req)
	if err != nil {
		return "", 0, "", nil, fmt.Errorf("HTTP GET failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	log.Printf("pow: fetchPoW HTTP status=%d", resp.StatusCode)

	body, err := readDecompressedBody(resp)
	if err != nil {
		return "", 0, "", nil, fmt.Errorf("read body (Content-Encoding=%q): %w",
			resp.Header.Get("Content-Encoding"), err)
	}
	// Phase 3 diagnostic: log cookies the jar received from the page GET.
	// Real Safari accumulates remixlang/remixstid/remixstlid here and
	// replays them on subsequent api.vk.ru POSTs. Verify our jar does the
	// same — if it shows zero cookies after the page GET, that's a strong
	// signal the missing cookies are part of the BOT detection.
	logCookiesForURL(client.Jar, "https://api.vk.ru", "fetchPoW post-GET (api.vk.ru)")
	logCookiesForURL(client.Jar, "https://id.vk.ru", "fetchPoW post-GET (id.vk.ru)")
	html := string(body)

	powRe := regexp.MustCompile(`const\s+powInput\s*=\s*"([^"]+)"`)
	m := powRe.FindStringSubmatch(html)
	if len(m) < 2 {
		preview := html
		if len(preview) > 500 {
			preview = preview[:500]
		}
		log.Printf("pow: HTML preview: %s", preview)
		return "", 0, "", nil, fmt.Errorf("powInput not found in HTML (%d bytes)", len(html))
	}
	powInput = m[1]

	diffRe := regexp.MustCompile(`startsWith\('0'\.repeat\((\d+)\)\)`)
	dm := diffRe.FindStringSubmatch(html)
	difficulty = 2
	if len(dm) >= 2 {
		if d, e := strconv.Atoi(dm[1]); e == nil {
			difficulty = d
		}
	}

	// Also extract captcha_settings from window.init (for slider solver)
	initRe := regexp.MustCompile(`(?s)window\.init\s*=\s*(\{.*?\})\s*;\s*window\.lang`)
	if initMatch := initRe.FindStringSubmatch(html); len(initMatch) >= 2 {
		var initPayload map[string]interface{}
		if err := json.Unmarshal([]byte(initMatch[1]), &initPayload); err == nil {
			if data, ok := initPayload["data"].(map[string]interface{}); ok {
				htmlSettings = map[string]interface{}{"response": data}
				showType, _ := data["show_captcha_type"].(string)
				log.Printf("pow: HTML captcha settings found (show_captcha_type=%q)", showType)
			}
		}
	}

	// Extract captcha JS bundle URL — used by fetchAndCacheDebugInfo to
	// pull the version-specific debug_info constant. The URL contains a
	// vkid/<version>/ path component that auto-invalidates our cache when
	// VK bumps the captcha bundle.
	if m := captchaJSRegex.FindStringSubmatch(html); len(m) >= 2 {
		scriptURL = m[1]
		log.Printf("pow: captcha script URL %s", scriptURL)
	} else {
		log.Printf("pow: captcha script URL not found in HTML — debug_info will use hardcoded fallback")
	}

	return powInput, difficulty, scriptURL, htmlSettings, nil
}


// solvePoW brute-forces SHA-256(powInput + nonce) until the hash
// starts with `difficulty` leading zeros.
func solvePoW(powInput string, difficulty int) string {
	target := strings.Repeat("0", difficulty)
	for nonce := 1; nonce <= 10_000_000; nonce++ {
		data := powInput + strconv.Itoa(nonce)
		h := sha256.Sum256([]byte(data))
		hexH := hex.EncodeToString(h[:])
		if strings.HasPrefix(hexH, target) {
			return hexH
		}
	}
	return ""
}

// readDecompressedBody reads an HTTP response body, transparently
// decompressing it based on the Content-Encoding header. Needed because
// when we set Accept-Encoding manually (gzip, deflate, br, zstd — to
// match Safari's TLS+HTTP fingerprint), Go's HTTP transport disables
// its built-in transparent gzip decompression and hands us the raw
// compressed bytes. We have to handle decoding ourselves.
//
// Why we set the header explicitly: Safari iOS 17 sends all four
// algorithms; Go's default (when header unset) is just `gzip`. The
// difference is a one-bit fingerprint VK can use to flag us as bot.
// See Phase 3 of the 2026-05-15 PoW regression investigation.
//
// brotli + zstd come from indirect deps already in go.sum (used by
// klauspost/compress and andybalholm/brotli transitively).
func readDecompressedBody(resp *http.Response) ([]byte, error) {
	enc := strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Encoding")))
	var reader io.Reader
	switch enc {
	case "", "identity":
		reader = resp.Body
	case "gzip":
		gz, err := gzip.NewReader(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("gzip decoder init: %w", err)
		}
		defer func() { _ = gz.Close() }()
		reader = gz
	case "deflate":
		zr := flate.NewReader(resp.Body)
		defer func() { _ = zr.Close() }()
		reader = zr
	case "br":
		// brotli.Reader has no Close (just an io.Reader).
		reader = brotli.NewReader(resp.Body)
	case "zstd":
		zr, err := zstd.NewReader(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("zstd decoder init: %w", err)
		}
		defer zr.Close()
		reader = zr
	default:
		return nil, fmt.Errorf("unsupported Content-Encoding: %q", enc)
	}
	return io.ReadAll(reader)
}

// safariAcceptEncoding matches what Safari iOS 17 sends literally.
// Set as a request header — see readDecompressedBody for the rationale.
const safariAcceptEncoding = "gzip, deflate, br, zstd"

// accessTokenSuffix is the Safari-canonical trailing form field on every
// captchaNotRobot.* body — an empty `access_token=` at the very end.
// Real Safari sends this after all per-method fields (sensors, browser_fp,
// hash, debug_info, etc.). Pre-build-94 we put `access_token=` 4th
// (right after adFp), giving same content but different byte order — a
// possible fingerprint difference. See callCaptchaNotRobotAPI for the
// position-by-position comparison with Safari capture 2026-05-15.
const accessTokenSuffix = "&access_token="

// logCookiesForURL logs the names of cookies that the jar would send to
// the given URL. Used for diagnostic visibility into whether the captcha
// session client is correctly accumulating + replaying VK cookies (real
// Safari sends remixlang/remixstid/remixstlid; we should too after the
// initial id.vk.ru GET in fetchPoW). Phase 3 diagnostic.
func logCookiesForURL(jar http.CookieJar, rawURL, label string) {
	if jar == nil {
		log.Printf("pow: %s cookie jar is nil", label)
		return
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		log.Printf("pow: %s cookie URL parse failed: %v", label, err)
		return
	}
	cookies := jar.Cookies(u)
	if len(cookies) == 0 {
		log.Printf("pow: %s NO cookies in jar for %s", label, u.Host)
		return
	}
	names := make([]string, len(cookies))
	for i, c := range cookies {
		names[i] = c.Name
	}
	log.Printf("pow: %s sending %d cookies to %s: %v", label, len(cookies), u.Host, names)
}

// genAdFp produces a 21-char base64url string used as the `adFp` form field
// in captchaNotRobot.check. Empirically (Safari WKWebView capture via Web
// Inspector, 2026-05-11) sync-loader.js from ad.mail.ru generates this
// client-side as a random tracking ID — VK validates only its presence and
// format, not its value (no cross-domain handshake with mail.ru). Until
// 2026-05-11 we sent `adFp=` empty in the POST body, which after VK tightened
// bot heuristics dropped PoW success from 88% (build 64 era) to 6% across
// 49+ attempts on two distinct captured fps. 16 random bytes → 22 base64url
// chars → truncated to 21 to match the empirically observed length.
func genAdFp() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	s := base64.RawURLEncoding.EncodeToString(b)
	if len(s) > 21 {
		s = s[:21]
	}
	return s
}

var (
	sessionAdFpVal  string
	sessionAdFpOnce sync.Once
)

// getSessionAdFp returns a process-stable adFp value, generated once on
// first call and reused for every subsequent solveCaptchaPoW. Mimics
// real Safari's window.rb_sync.id, which is generated by sync-loader.js
// and persisted in cookie + localStorage for the lifetime of the page
// (and across page reloads while the cookie is alive).
//
// Pre-build-91 we generated a fresh random per solveCaptchaPoW, meaning
// each of the 3 PoW retries (in creds.go) sent a different adFp. Real
// Safari sends the SAME adFp across all attempts within the same browser
// session — and across multiple captcha sessions, since rb_sync persists.
// The inconsistency was a candidate BOT signal during the 2026-05-15
// PoW regression investigation (Phase 1; see open question in chat
// session 76000841 for empirical context). NOT proven to be the cause —
// this is a hypothesis fix, will be evaluated empirically.
//
// Process-scoped (not user-scoped) deliberately: persisting to disk
// (vk_profile.json) would be more Safari-like but the value is opaque
// and we have no evidence it matters across process restarts. Easy to
// promote later if data warrants.
func getSessionAdFp() string {
	sessionAdFpOnce.Do(func() {
		sessionAdFpVal = genAdFp()
		log.Printf("pow: initialized session adFp=%s (process-stable; reused for all subsequent PoW solves)", sessionAdFpVal)
	})
	return sessionAdFpVal
}

// fetchAdFpPing fires the mail.ru tracking GET that real Safari makes when
// loading the VK ID not_robot_captcha page. Reproduced via curl from Mac
// 2026-05-11: the endpoint returns 200 OK with empty body (chunked, 0 bytes),
// no Set-Cookie — it's purely a mail.ru analytics hit. We replay it for two
// reasons: (1) match Safari's network footprint in case VK correlates with
// mail.ru-side request logs (low probability but cheap insurance), (2) any
// future Set-Cookie response would be picked up by the shared CookieJar.
// Errors are non-fatal — we log and continue.
//
// IMPORTANT: the `id` query param is a SEPARATE random ID from the adFp
// value sent to VK. Safari capture confirmed they differ within one session.
// sync-loader.js generates two independent 21-char IDs.
func fetchAdFpPing(ctx context.Context, client *http.Client) {
	pingID := genAdFp() // same generator, different value from the body adFp
	pingURL := "https://privacy-cs.mail.ru/fp/?id=" + pingID
	req, err := http.NewRequestWithContext(ctx, "GET", pingURL, nil)
	if err != nil {
		log.Printf("pow: fetchAdFpPing skipped (request creation failed: %v)", err)
		return
	}
	req.Header.Set("User-Agent", captchaPowProfile.UserAgent)
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Accept-Encoding", safariAcceptEncoding)
	req.Header.Set("Accept-Language", "en-GB,en;q=0.9")
	req.Header.Set("Origin", "https://id.vk.ru")
	req.Header.Set("Referer", "https://id.vk.ru/")
	req.Header.Set("Sec-Fetch-Dest", "empty")
	req.Header.Set("Sec-Fetch-Mode", "cors")
	req.Header.Set("Sec-Fetch-Site", "cross-site")

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("pow: fetchAdFpPing failed (non-fatal): %v", err)
		return
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, resp.Body)
	log.Printf("pow: adFp tracking ping sent (status=%d, id=%s)", resp.StatusCode, pingID)
}

// callCaptchaNotRobotAPI performs the 4-step VK captchaNotRobot protocol.
// Adapted from the reference implementation in PR #105 — uses simplified
// sensor data (empty arrays) and longer timing delays.
//
// Returns (successToken, lastShowCaptchaType, err). See solveCaptchaPoW for
// the meaning of lastShowCaptchaType.
func callCaptchaNotRobotAPI(ctx context.Context, client *http.Client, sessionToken, hash, adFp, debugInfo string, htmlSettings map[string]interface{}) (string, string, error) {
	vkReq := func(method, postData string) (map[string]interface{}, error) {
		reqURL := "https://api.vk.ru/method/" + method + "?v=5.131"
		req, err := http.NewRequestWithContext(ctx, "POST", reqURL, strings.NewReader(postData))
		if err != nil {
			return nil, err
		}
		// Headers calibrated against real Safari iOS 17 WKWebView capture
		// (Web Inspector → Network → captchaNotRobot.check, 2026-05-11).
		// Removed: sec-ch-ua / sec-ch-ua-mobile / sec-ch-ua-platform (Chrome
		// Client Hints — Safari does NOT send them and our captured browser_fp
		// was computed for Safari mobile, so sending Chrome hints with Safari
		// UA was a double mismatch). Removed: DNT (Safari dropped years ago),
		// Sec-GPC (Brave/Firefox-only signal). Changed: Accept-Language to
		// en-GB matching captured device.language. Added: Cache-Control,
		// Pragma, Priority — all present in Safari capture.
		req.Header.Set("User-Agent", captchaPowProfile.UserAgent)
		req.Header.Set("Accept", "*/*")
		req.Header.Set("Accept-Encoding", safariAcceptEncoding)
		req.Header.Set("Accept-Language", "en-GB,en;q=0.9")
		req.Header.Set("Cache-Control", "no-cache")
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", "https://id.vk.ru")
		req.Header.Set("Pragma", "no-cache")
		req.Header.Set("Priority", "u=3, i")
		req.Header.Set("Referer", "https://id.vk.ru/")
		req.Header.Set("Sec-Fetch-Dest", "empty")
		req.Header.Set("Sec-Fetch-Mode", "cors")
		req.Header.Set("Sec-Fetch-Site", "same-site")

		// Phase 3 diagnostic: surface what cookies we're sending to VK.
		// Real Safari sends remixlang/remixstid/remixstlid on every
		// captchaNotRobot.* call; we should too after fetchPoW (which
		// GETs id.vk.ru/not_robot_captcha and should accumulate
		// Set-Cookie headers in the shared jar).
		logCookiesForURL(client.Jar, reqURL, method)

		httpResp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("HTTP POST %s failed: %w", method, err)
		}
		defer func() { _ = httpResp.Body.Close() }()

		body, err := readDecompressedBody(httpResp)
		if err != nil {
			return nil, fmt.Errorf("read body (Content-Encoding=%q): %w",
				httpResp.Header.Get("Content-Encoding"), err)
		}

		log.Printf("pow: %s response: %s", method, string(body[:min(300, len(body))]))

		var resp map[string]interface{}
		if err := json.Unmarshal(body, &resp); err != nil {
			return nil, fmt.Errorf("unmarshal: %w", err)
		}
		return resp, nil
	}

	domain := "vk.com"
	// adFp: 21-char base64url tracking ID generated client-side in real
	// Safari by sync-loader.js. Until 2026-05-11 we sent it empty and PoW
	// success collapsed to ~6% after VK started enforcing its presence.
	// See genAdFp + fetchAdFpPing for full mechanism.
	//
	// Body order: session_token & domain & adFp first, then per-method
	// fields (sensors / browser_fp / hash / answer / debug_info), then
	// access_token LAST. Matches Safari capture order byte-for-byte
	// (2026-05-15 captchaNotRobot.check.curl). Pre-build-94 we put
	// access_token=4th and other fields after — same content, different
	// byte order, possibly a fingerprint difference. Phase 3 fix.
	baseParams := fmt.Sprintf("session_token=%s&domain=%s&adFp=%s",
		url.QueryEscape(sessionToken), url.QueryEscape(domain), url.QueryEscape(adFp))

	// Extract HTML-level show_captcha_type hint. VK embeds a `window.init.data`
	// payload in the captcha page that announces which challenge type VK plans
	// to render. Empirically:
	//   - "slider"   : VK is in slider-only mode (checkbox disabled). Every
	//                  subsequent captchaNotRobot.check returns status=ERROR.
	//                  Skipping the check saves ~3 seconds (2.5s artificial
	//                  delay + HTTP round-trip) on every solveCaptchaPoW call.
	//   - "checkbox" : normal mode, checkbox may succeed — proceed as usual.
	htmlShowType := ""
	if htmlSettings != nil {
		if resp, ok := htmlSettings["response"].(map[string]interface{}); ok {
			if s, ok := resp["show_captcha_type"].(string); ok {
				htmlShowType = s
			}
		}
	}
	// lastShowType is what we return to the caller as the last known
	// show_captcha_type signal. Seeded from the HTML hint; overwritten by the
	// API check response if we make one.
	lastShowType := htmlShowType

	// 1/4: settings
	//
	// Phase 5 (build 97) skipped this and componentDone on the
	// hypothesis that Safari WKWebView capture's Web Inspector showed
	// only check + endSession. EMPIRICALLY DISPROVED — BOT rate
	// stayed at 100% (vpn.wifi.8.log). Reverted in build 98.
	// Cross-check with Moroka8/vk-turn-proxy commit 21cf9fa shows
	// they DO call settings + componentDone — Safari's Inspector
	// likely missed them due to caching or filter, not absence.
	log.Printf("pow: 1/4 captchaNotRobot.settings")
	settingsResp, err := vkReq("captchaNotRobot.settings", baseParams+accessTokenSuffix)
	if err != nil {
		return "", lastShowType, fmt.Errorf("settings: %w", err)
	}

	// Short delay after settings (100-200ms) — matches reference impl
	time.Sleep(time.Duration(100+mathrand.Intn(100)) * time.Millisecond)

	// 2/4: componentDone
	log.Printf("pow: 2/4 captchaNotRobot.componentDone")

	// Default: generated browser_fp + canned device descriptor. VK's
	// anti-bot scoring catches this pattern almost every time
	// (status=BOT on .check, see vpn.wifi.0.log analysis 2026-05-08
	// where 62/66 fresh fetches got BOT). If we have a captured real
	// browser profile from a prior manual solve in CaptchaWKWebView,
	// use those values instead — they pass VK's check because they
	// were originally produced and accepted by VK's own JS.
	browserFp := fmt.Sprintf("%x%x", mathrand.Int63(), mathrand.Int63())

	deviceMap := map[string]interface{}{
		"screenWidth":             1920,
		"screenHeight":            1080,
		"screenAvailWidth":        1920,
		"screenAvailHeight":       1040,
		"innerWidth":              1903,
		"innerHeight":             969,
		"devicePixelRatio":        1,
		"language":                "en-US",
		"languages":               []string{"en-US", "en", "ru"},
		"webdriver":               false,
		"hardwareConcurrency":     8,
		"deviceMemory":            8,
		"connectionEffectiveType": "4g",
		"notificationsPermission": "default",
	}
	deviceBytes, _ := json.Marshal(deviceMap)
	deviceParam := url.QueryEscape(string(deviceBytes))

	if saved := loadSavedVKProfile(); saved != nil {
		ageDays := (float64(time.Now().Unix()) - saved.CapturedAt) / 86400.0
		log.Printf("pow: using captured browser profile (browser_fp=%dc, device=%dc, captured %.1f days ago)",
			len(saved.BrowserFp), len(saved.Device), ageDays)
		browserFp = saved.BrowserFp
		// saved.Device is the raw value from the captured request body,
		// which was already URL-encoded form-data. Pass through as-is —
		// re-encoding would double-escape the JSON braces and quotes.
		deviceParam = saved.Device
	} else {
		log.Printf("pow: no captured browser profile, using generated browser_fp+device")
	}

	componentData := baseParams + fmt.Sprintf("&browser_fp=%s&device=%s", browserFp, deviceParam) + accessTokenSuffix

	if _, err := vkReq("captchaNotRobot.componentDone", componentData); err != nil {
		return "", lastShowType, fmt.Errorf("componentDone: %w", err)
	}

	// 3/4: check (checkbox-style).
	//
	// We always attempt the checkbox check regardless of past responses.
	// Empirically VK's status=ERROR is transient ("captcha type unavailable
	// right now") rather than permanent — a previous version cached a
	// session-wide "burned" flag on the first ERROR and skipped checkbox
	// forever, but that wedged the pool grower whenever VK returned a
	// single ERROR (slider also fails ~100% in our environment, so once
	// burned, every subsequent solveCaptchaPoW returned an error and the
	// pool decayed to empty). Now we just retry the checkbox each call;
	// if it returns ERROR/BOT/ERROR_LIMIT we still fall through to the
	// slider attempt within the same call.
	{
		// Longer pause before check (1950-3200ms) — matches reference HAR timing
		checkDelay := time.Duration(1950+mathrand.Intn(1250)) * time.Millisecond
		log.Printf("pow: waiting %s before check", checkDelay.Round(time.Millisecond))
		select {
		case <-time.After(checkDelay):
		case <-ctx.Done():
			return "", lastShowType, ctx.Err()
		}

		log.Printf("pow: 3/4 captchaNotRobot.check")

		// Sensor arrays empty across the board — confirmed by Safari
		// WKWebView capture 2026-05-15 (captchaNotRobot.check.curl).
		// Real Safari sends `cursor=[]` and `connectionDownlink=[]`,
		// not fake-but-realistic data we used to send. The fake data
		// (5 cursor positions + 7 downlink floats) was a try-too-hard
		// mistake from build 85 era — real iOS Safari just sends []
		// for checkbox-style captcha (sensor data is only relevant
		// for slider variant). Sending fake values gave VK an extra
		// signal to detect us; reverting matches Safari exactly.
		cursorBytes := []byte("[]")
		downlinkBytes := []byte("[]")

		answer := base64.StdEncoding.EncodeToString([]byte("{}"))

		// debug_info — passed in from solveCaptchaPoW.
		// fetchAndCacheDebugInfo extracts the version-specific constant
		// from not_robot_captcha.js dynamically (Phase 6 of 2026-05-15
		// PoW regression investigation, ported from Moroka8 v2 solver).
		// Falls back to the canonical "a0ac4896..." constant on any
		// extraction failure. See callCaptchaNotRobotAPI sig + Phase 2
		// commentary in build 93 for the original hardcoded reasoning.

		checkData := baseParams + fmt.Sprintf(
			"&accelerometer=%s&gyroscope=%s&motion=%s&cursor=%s&taps=%s&connectionRtt=%s&connectionDownlink=%s"+
				"&browser_fp=%s&hash=%s&answer=%s&debug_info=%s",
			url.QueryEscape("[]"),
			url.QueryEscape("[]"),
			url.QueryEscape("[]"),
			url.QueryEscape(string(cursorBytes)),
			url.QueryEscape("[]"),
			url.QueryEscape("[]"),
			url.QueryEscape(string(downlinkBytes)),
			browserFp,
			hash,
			answer,
			debugInfo,
		) + accessTokenSuffix

		checkResp, err := vkReq("captchaNotRobot.check", checkData)
		if err != nil {
			return "", lastShowType, fmt.Errorf("check: %w", err)
		}

		respObj, ok := checkResp["response"].(map[string]interface{})
		if !ok {
			return "", lastShowType, fmt.Errorf("check: invalid response: %v", checkResp)
		}
		status, _ := respObj["status"].(string)
		showCaptchaType, _ := respObj["show_captcha_type"].(string)
		// Overwrite the HTML-seeded hint with VK's explicit API response.
		lastShowType = showCaptchaType

		if status == "OK" {
			successToken, ok := respObj["success_token"].(string)
			if !ok || successToken == "" {
				return "", lastShowType, fmt.Errorf("check: no success_token in response")
			}
			time.Sleep(200 * time.Millisecond)
			log.Printf("pow: 4/4 captchaNotRobot.endSession")
			_, err = vkReq("captchaNotRobot.endSession", baseParams+accessTokenSuffix)
			if err != nil {
				log.Printf("pow: endSession failed (non-fatal): %v", err)
			}
			return successToken, lastShowType, nil
		}

		// Checkbox check failed. ALL non-OK statuses are treated as transient
		// — a future solveCaptchaPoW call will retry the checkbox. Falls
		// through to the slider attempt below as an in-call fallback.
		log.Printf("pow: checkbox failure (status=%s, show_captcha_type=%s) — falling through to slider; next solveCaptchaPoW call will retry checkbox", status, showCaptchaType)
	}

	// Try slider solver regardless of show_captcha_type — VK may not always
	// include it in the check response, but getContent may still work
	// Merge settings from API response and HTML page (HTML has slider settings
	// that the API response doesn't include)
	mergedSettings := settingsResp
	if htmlSettings != nil {
		mergedSettings = htmlSettings
		log.Printf("pow: using HTML-extracted captcha settings for slider")
	}
	log.Printf("pow: attempting automatic slider solver...")
	sliderToken, sliderErr := solveSliderCaptcha(vkReq, baseParams, browserFp, deviceParam, hash, mergedSettings)
	if sliderErr == nil && sliderToken != "" {
		log.Printf("pow: slider solver succeeded!")
		time.Sleep(200 * time.Millisecond)
		log.Printf("pow: 4/4 captchaNotRobot.endSession")
		if _, esErr := vkReq("captchaNotRobot.endSession", baseParams+accessTokenSuffix); esErr != nil {
			log.Printf("pow: endSession failed (non-fatal): %v", esErr)
		}
		return sliderToken, lastShowType, nil
	}
	log.Printf("pow: slider solver failed: %v", sliderErr)
	return "", lastShowType, fmt.Errorf("checkbox check failed and slider also failed: %v", sliderErr)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
