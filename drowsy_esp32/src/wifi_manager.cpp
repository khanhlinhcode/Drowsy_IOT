#include "wifi_manager.h"
#include <ArduinoJson.h>
#include <esp_wifi.h>

WifiManager::WifiManager() : _cfg(), _server(80) {}

WifiManager::WifiManager(const Config& config) : _cfg(config), _server(80) {}

constexpr uint16_t WifiManager::CAPTIVE_DNS_PORT;

static String htmlEscape(const String& value) {
  String out;
  out.reserve(value.length() + 16);
  for (size_t i = 0; i < value.length(); ++i) {
    const char c = value[i];
    switch (c) {
      case '&':
        out += F("&amp;");
        break;
      case '<':
        out += F("&lt;");
        break;
      case '>':
        out += F("&gt;");
        break;
      case '"':
        out += F("&quot;");
        break;
      case '\'':
        out += F("&#39;");
        break;
      default:
        out += c;
        break;
    }
  }
  return out;
}

static const char* flowStateName(WifiManager::FlowState state) {
  switch (state) {
    case WifiManager::FLOW_BOOT:
      return "BOOT";
    case WifiManager::FLOW_STA_CONNECT:
      return "STA_CONNECT";
    case WifiManager::FLOW_PORTAL:
      return "PORTAL";
    case WifiManager::FLOW_RECONNECT:
      return "RECONNECT";
  }
  return "UNKNOWN";
}

void WifiManager::begin(const char* apPrefix) {
  _flowState = FLOW_BOOT;
  _apPrefix = String(apPrefix == nullptr ? "DrowsySetup" : apPrefix);
  _lastConnectedMs = millis();
  _wifiState = WIFI_DISCONNECTED;
  _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
  _fastRetryLeft = 0;
  _nextWifiRetryMs = 0;
  _lastInternetCheckMs = 0;
  _lastPiCredEmitMs = 0;
  _lastPiConnectedEmitMs = 0;
  _lastPiSyncRequestMs = 0;
  _lastPiBridgeSeenMs = 0;
  _captiveSuccessUntilMs = 0;
  _captiveSuccessClientIp = IPAddress(0, 0, 0, 0);

  WiFi.mode(WIFI_STA);
  // FIX: keep credentials persistent for roaming/reconnect stability.
  WiFi.persistent(true);
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(false);
  // CRITICAL: disable power save to reduce roaming jitter on moving vehicles.
  esp_wifi_set_ps(WIFI_PS_NONE);

  if (_prefs.begin(_cfg.nvsNamespace, false)) {
    _prefsReady = true;
    loadCredentials();
  }

  setupRoutes();

  if (_cfg.alwaysOnPortal) {
    startPortal();
  }

  if (hasCredentials()) {
    _fastRetryLeft = WIFI_FAST_RETRY_ATTEMPTS_BOOT;
    _flowState = FLOW_STA_CONNECT;
    beginConnect(millis());
  } else {
    _flowState = FLOW_PORTAL;
    startPortal();
  }
}

void WifiManager::tick(uint32_t nowMs) {
  if (_portalRunning) {
    _dns.processNextRequest();
    _server.handleClient();
  }

  wl_status_t st = WiFi.status();
  const bool hasIp = WiFi.localIP() != IPAddress(0, 0, 0, 0);
  if (st == WL_CONNECTED && hasIp) {
    if (_wifiState != WIFI_CONNECTED) {
      Serial.println("[WIFI] CONNECTED");
      emitPiWifiConnected();
      _lastPiConnectedEmitMs = nowMs;
      _lastConnectedMs = nowMs;
      _wifiState = WIFI_CONNECTED;
      _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
      _fastRetryLeft = 0;
      _nextWifiRetryMs = nowMs;
      _wifiConnectStartMs = 0;
      if (_portalRunning && !_cfg.alwaysOnPortal) {
        stopPortal();
      }
      // Refresh captive success window when WiFi is truly connected.
      // This avoids premature expiry on slow AP association.
      if (_captiveSuccessClientIp != IPAddress(0, 0, 0, 0)) {
        _captiveSuccessUntilMs = nowMs + CAPTIVE_SUCCESS_WINDOW_MS;
      }
    }
    _flowState = FLOW_STA_CONNECT;   // NEW
    _wasConnected = true;

    // Keep Pi-side WiFi sync robust when Pi boots later than ESP32.
    if ((nowMs - _lastPiConnectedEmitMs) >= PI_CONNECTED_EMIT_INTERVAL_MS) {
      emitPiWifiConnected();
      _lastPiConnectedEmitMs = nowMs;
    }
    if ((nowMs - _lastPiCredEmitMs) >= PI_CRED_EMIT_INTERVAL_MS) {
      emitPiWifiCredentials();
      _lastPiCredEmitMs = nowMs;
    }
    

    if ((nowMs - _lastInternetCheckMs) >= _cfg.internetCheckIntervalMs) {
      _lastInternetCheckMs = nowMs;
      // FIX: detect fake connected state with lightweight internet probe.
      if (!hasInternet()) {
        Serial.println("[WIFI] LOST");
        WiFi.disconnect(false, false);
        _wifiState = WIFI_DISCONNECTED;
        _nextWifiRetryMs = nowMs;
      }
    }
    return;
  }

  if (_wifiState == WIFI_CONNECTED) {
    Serial.println("[WIFI] LOST");
    _wifiState = WIFI_DISCONNECTED;
    _nextWifiRetryMs = nowMs;
  }

  // Fail fast on terminal WiFi states instead of waiting full timeout.
  if (_wifiState == WIFI_CONNECTING &&
      (st == WL_CONNECT_FAILED || st == WL_NO_SSID_AVAIL || st == WL_CONNECTION_LOST)) {
    Serial.print("[WIFI] FAIL status=");
    Serial.println(static_cast<int>(st));
    WiFi.disconnect(false, false);
    _wifiState = WIFI_DISCONNECTED;
    _flowState = FLOW_RECONNECT;
    uint32_t retryDelayMs = _wifiBackoffMs;
    if (_fastRetryLeft > 0) {
      retryDelayMs = WIFI_FAST_RETRY_MS;
      _fastRetryLeft--;
    } else {
      _wifiBackoffMs = min(_wifiBackoffMs * 2U, WIFI_BACKOFF_MAX_MS);
    }
    _nextWifiRetryMs = nowMs + retryDelayMs;
  }

  _wasConnected = false;

  if (_wifiState == WIFI_CONNECTING && (nowMs - _wifiConnectStartMs) > _cfg.connectTimeoutMs) {
    // CRITICAL: break stuck CONNECTING state with timeout.
    Serial.println("[WIFI] TIMEOUT");
    WiFi.disconnect(true, false);
    _wifiState = WIFI_DISCONNECTED;
    _flowState = FLOW_RECONNECT;
    uint32_t retryDelayMs = _wifiBackoffMs;
    if (_fastRetryLeft > 0) {
      retryDelayMs = WIFI_FAST_RETRY_MS;
      _fastRetryLeft--;
    } else {
      _wifiBackoffMs = min(_wifiBackoffMs * 2U, WIFI_BACKOFF_MAX_MS);
    }
    _nextWifiRetryMs = nowMs + retryDelayMs;
  }

  if (_wifiState == WIFI_DISCONNECTED && hasCredentials() && nowMs >= _nextWifiRetryMs) {
    _flowState = FLOW_RECONNECT;  
    beginConnect(nowMs);
  }

  // If disconnected for long time, expose AP portal for reconfiguration.
  if (!_portalRunning) {
    const bool noCreds = !hasCredentials();
    const bool disconnectedLong = (nowMs - _lastConnectedMs) >= _cfg.portalFallbackMs;
    if (_cfg.alwaysOnPortal || noCreds || disconnectedLong) {
      _flowState = FLOW_PORTAL;      
      startPortal();
    }
  }
}

bool WifiManager::isConnected() const {
  return _wifiState == WIFI_CONNECTED && WiFi.status() == WL_CONNECTED;
}

bool WifiManager::hasCredentials() const { return _ssid.length() > 0; }

bool WifiManager::portalActive() const { return _portalRunning; }

String WifiManager::connectedSsid() const { return _ssid; }

IPAddress WifiManager::localIP() const { return WiFi.localIP(); }

void WifiManager::clearCredentials() {
  _ssid = "";
  _password = "";
  if (_prefsReady) {
    _prefs.remove("ssid");
    _prefs.remove("pass");
  }
  WiFi.disconnect(false, true);
  _wifiState = WIFI_DISCONNECTED;
  _wifiConnectStartMs = 0;
  _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
  _fastRetryLeft = 0;
  _nextWifiRetryMs = millis() + _wifiBackoffMs;
  startPortal();
}

void WifiManager::openPortal() {
  // Force-open AP config portal WITHOUT clearing saved credentials.
  // The user can enter new credentials, or cancel and the ESP32 will
  // continue trying the existing saved credentials.
  _flowState = FLOW_PORTAL;
  startPortal();
  Serial.println("[WIFI] Portal forced open (credentials preserved)");
}

void WifiManager::loadCredentials() {
  if (!_prefsReady) return;
  _ssid = _prefs.getString("ssid", "");
  _password = _prefs.getString("pass", "");
}

void WifiManager::saveCredentials(const String& ssid, const String& password) {
  _ssid = ssid;
  _password = password;
  if (!_prefsReady) return;
  _prefs.putString("ssid", _ssid);
  _prefs.putString("pass", _password);
}

void WifiManager::beginConnect(uint32_t nowMs) {
  if (!hasCredentials()) return;
  emitPiWifiCredentials();
  _lastPiCredEmitMs = nowMs;

  WiFi.mode(_portalRunning ? WIFI_AP_STA : WIFI_STA);
  // Ensure clean reconnect attempt on unstable roaming links.
  WiFi.disconnect(false, false);
  WiFi.persistent(true);
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(false);
  // CRITICAL: enforce no WiFi power save during reconnection cycles.
  esp_wifi_set_ps(WIFI_PS_NONE);
  Serial.println("[WIFI] CONNECTING");
  WiFi.begin(_ssid.c_str(), _password.c_str());

  _wifiState = WIFI_CONNECTING;
  _wifiConnectStartMs = nowMs;
  _nextWifiRetryMs = nowMs + ((_fastRetryLeft > 0) ? WIFI_FAST_RETRY_MS : _wifiBackoffMs);
}

void WifiManager::requestPiSync(uint32_t nowMs) {
  if (nowMs == 0) nowMs = millis();
  if ((nowMs - _lastPiSyncRequestMs) < PI_SYNC_REQUEST_GAP_MS) return;
  _lastPiSyncRequestMs = nowMs;

  // FIX: force=true when responding to Pi sync request — always emit even if same credentials
  // were sent recently, because Pi may have missed the previous transmission.
  emitPiWifiCredentials(true);
  _lastPiCredEmitMs = nowMs;
  if (isConnected()) {
    emitPiWifiConnected();
    _lastPiConnectedEmitMs = nowMs;
  }
}

void WifiManager::notifyPiBridgeSeen(uint32_t nowMs) {
  if (nowMs == 0) nowMs = millis();
  _lastPiBridgeSeenMs = nowMs;
}

bool WifiManager::isPiBridgeRecent(uint32_t nowMs) const {
  if (_lastPiBridgeSeenMs == 0) return false;
  if (nowMs == 0) nowMs = millis();
  return (nowMs - _lastPiBridgeSeenMs) <= PI_BRIDGE_FRESH_MS;
}

void WifiManager::emitPiWifiCredentials(bool force) {
  if (!hasCredentials()) return;
  static uint32_t sLastEmitMs = 0;
  static uint32_t sLastSigHash = 0;
  const uint32_t nowMs = millis();
  uint32_t sigHash = 2166136261u;
  for (size_t i = 0; i < _ssid.length(); ++i) {
    sigHash ^= static_cast<uint8_t>(_ssid[i]);
    sigHash *= 16777619u;
  }
  sigHash ^= static_cast<uint8_t>('|');
  sigHash *= 16777619u;
  for (size_t i = 0; i < _password.length(); ++i) {
    sigHash ^= static_cast<uint8_t>(_password[i]);
    sigHash *= 16777619u;
  }
  // FIX: force=true bypasses dedup to ensure Pi always receives credentials
  // even when same credentials were sent recently (e.g., Pi missed previous TX).
  if (!force && sigHash == sLastSigHash && (nowMs - sLastEmitMs) < PI_CRED_MIN_GAP_MS) {
    return;
  }
  sLastSigHash = sigHash;
  sLastEmitMs = nowMs;
  // Credentials are sent over local serial for Pi auto-provisioning.
  JsonDocument doc;
  doc["type"] = "wifi_credentials";
  doc["ssid"] = _ssid;
  doc["pass"] = _password;
  char payload[192];
  size_t n = serializeJson(doc, payload, sizeof(payload));
  if (n == 0 || n >= sizeof(payload)) return;
  Serial.print("[ESP32_WIFI] ");
  Serial.println(payload);
  Serial.print("[ESP32_WIFI] credentials emitted ssid=");
  Serial.println(_ssid);
}

void WifiManager::emitPiWifiConnected() {
  JsonDocument doc;
  doc["type"] = "wifi_connected";
  doc["ssid"] = _ssid;
  doc["esp_ip"] = WiFi.localIP().toString();
  char payload[192];
  size_t n = serializeJson(doc, payload, sizeof(payload));
  if (n == 0 || n >= sizeof(payload)) return;
  Serial.print("[ESP32_WIFI] ");
  Serial.println(payload);
}

bool WifiManager::hasInternet() {
  if (!_cfg.requireInternet) return true;

  WiFiClient client;
  client.setTimeout(150);
  const bool ok = client.connect(_cfg.healthHost, _cfg.healthPort);
  if (ok) client.stop();
  return ok;
}

void WifiManager::startPortal() {
  if (_portalRunning) return;

  uint64_t chip = ESP.getEfuseMac();
  char suffix[9];
  snprintf(suffix, sizeof(suffix), "%08X", static_cast<uint32_t>(chip & 0xFFFFFFFFu));

  if (_cfg.rotateApSsidPerBoot) {
    if (_apSessionTag == 0) {
      const uint32_t seed =
          static_cast<uint32_t>(chip & 0xFFFFFFFFu) ^
          static_cast<uint32_t>(micros()) ^
          static_cast<uint32_t>(millis());
      uint16_t tag = static_cast<uint16_t>((seed ^ (seed >> 16)) & 0xFFFFu);
      if (tag == 0) tag = 0xA5A5;
      _apSessionTag = tag;
    }
    char session[5];
    snprintf(session, sizeof(session), "%04X", _apSessionTag);
    _apSsid = _apPrefix + "-" + String(suffix) + "-" + String(session);
  } else {
    _apSsid = _apPrefix + "-" + String(suffix);
  }

  // AP SSID max length is 32 bytes.
  if (_apSsid.length() > 32) {
    _apSsid = _apPrefix + "-" + String(suffix);
  }

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(_apSsid.c_str(), _cfg.apPassword);
  _dns.stop();
  _dns.setErrorReplyCode(DNSReplyCode::NoError);
  _dns.start(CAPTIVE_DNS_PORT, "*", WiFi.softAPIP());
  _server.begin();
  Serial.print("[WIFI] portal AP=");
  Serial.print(_apSsid);
  Serial.print(" ip=");
  Serial.print(WiFi.softAPIP());
  Serial.print(" always_on=");
  Serial.println(_cfg.alwaysOnPortal ? "ON" : "OFF");
  _portalRunning = true;
}

void WifiManager::stopPortal() {
  if (!_portalRunning) return;
  _dns.stop();
  _server.stop();
  WiFi.softAPdisconnect(true);
  _portalRunning = false;
}

void WifiManager::setupRoutes() {
  _server.on("/", HTTP_GET, [this]() { handleRoot(); });
  _server.on("/save", HTTP_POST, [this]() { handleSave(); });
  _server.on("/save", HTTP_GET, [this]() { handleSave(); });
  _server.on("/status", HTTP_GET, [this]() { handleStatus(); });
  _server.on("/scan", HTTP_GET, [this]() { handleScan(); });
  // Common captive-probe endpoints across mobile/laptop OS versions.
  _server.on("/generate_204", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/gen_204", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/mobile/status.php", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/hotspot-detect.html", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/canonical.html", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/ncsi.txt", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/check_network_status.txt", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/library/test/success.html", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/kindle-wifi/wifistub.html", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/connecttest.txt", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/success.txt", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/connectivity-check.html", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/fwlink", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.on("/redirect", HTTP_GET, [this]() { handleCaptiveProbe(); });
  _server.onNotFound([this]() { handleCaptiveProbe(); });
}

void WifiManager::handleCaptiveProbe() {
  const uint32_t nowMs = millis();
  const bool inSuccessWindow =
      (_captiveSuccessUntilMs != 0) &&
      (static_cast<int32_t>(_captiveSuccessUntilMs - nowMs) > 0);
  const bool hasSuccessClient = _captiveSuccessClientIp != IPAddress(0, 0, 0, 0);
  // Allow success probes during the completion window even if the OS captive
  // helper changes source IP/process between requests.
  const bool successAllowed = inSuccessWindow;
  const String uri = _server.uri();

  if (!inSuccessWindow && hasSuccessClient) {
    _captiveSuccessUntilMs = 0;
    _captiveSuccessClientIp = IPAddress(0, 0, 0, 0);
  }

  // --- SUCCESS WINDOW: allow OS to mark internet as available ---
  if (successAllowed) {
    _server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate");
    _server.sendHeader("Pragma", "no-cache");
    _server.sendHeader("Expires", "-1");
    if (uri == "/generate_204" || uri == "/gen_204") {
      _server.send(204, "text/plain", "");
    } else if (uri == "/hotspot-detect.html" || uri == "/canonical.html") {
      _server.send(200, "text/html", "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>");
    } else if (uri == "/ncsi.txt") {
      _server.send(200, "text/plain", "Microsoft NCSI");
    } else if (uri == "/connecttest.txt" || uri == "/success.txt") {
      _server.send(200, "text/plain", "success");
    } else if (uri == "/fwlink") {
      _server.send(200, "text/plain", "Microsoft Connect Test");
    } else {
      _server.send(200, "text/plain", "OK");
    }
    return;
  }

  // --- CAPTIVE STATE: always 302-redirect to open portal popup ---
  // iOS/Android/Windows CNA all require a 302 redirect (NOT inline HTML)
  // to the captive portal IP to trigger the auto-popup dialog.
  redirectToPortal();
}

void WifiManager::redirectToPortal() {
  const String target = String("http://") + WiFi.softAPIP().toString() + "/";
  _server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate");
  _server.sendHeader("Pragma", "no-cache");
  _server.sendHeader("Expires", "-1");
  _server.sendHeader("Location", target, true);
  String html;
  html.reserve(320);
  html += F("<!doctype html><html><head><meta charset='utf-8'>");
  html += F("<meta http-equiv='refresh' content='0;url=");
  html += target;
  html += F("'>");
  html += F("<title>Drowsy Setup</title></head><body>");
  html += F("Redirecting to setup portal... / Dang chuyen sang trang cai dat...<br>");
  html += F("<a href='");
  html += target;
  html += F("'>Open Drowsy Setup</a>");
  html += F("</body></html>");
  _server.send(302, "text/html", html);
}

void WifiManager::handleScan() {
  // Non-blocking scan: return cached results from last background scan.
  int n = WiFi.scanComplete();
  if (n == WIFI_SCAN_RUNNING) {
    _server.send(202, "application/json", "{\"scanning\":true}");
    return;
  }
  if (n <= 0) {
    // Start async scan and return empty list — client should retry.
    WiFi.scanNetworks(true);
    _server.send(200, "application/json", "[]");
    return;
  }
  String out;
  out.reserve(n * 48);
  out += "[";
  for (int i = 0; i < n; ++i) {
    if (i > 0) out += ",";
    out += "{\"s\":";
    out += "\"";
    out += htmlEscape(WiFi.SSID(i));
    out += "\",\"r\":";
    out += WiFi.RSSI(i);
    out += ",\"e\":";
    out += (WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? 0 : 1);
    out += "}";
  }
  out += "]";
  _server.send(200, "application/json", out);
  // Kick off next scan so it's ready next time.
  WiFi.scanDelete();
  WiFi.scanNetworks(true);
}

void WifiManager::handleRoot() {
  // Kick off a background WiFi scan for the SSID dropdown.
  if (WiFi.scanComplete() == WIFI_SCAN_FAILED) {
    WiFi.scanNetworks(true);
  }

  String html;
  html.reserve(6800);
  html += F("<!doctype html><html lang='en'><head><meta charset='utf-8'>");
  html += F("<meta name='viewport' content='width=device-width,initial-scale=1'>");
  html += F("<title>Drowsy WiFi Setup</title>");
  html += F("<style>");
  html += F("*{box-sizing:border-box}");
  html += F("body{margin:0;min-height:100vh;padding:16px;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 18% 10%,#1e3a5f 0%,#0d1c30 50%,#060c18 100%);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#e8f2ff}");
  html += F(".card{width:min(480px,100%);background:linear-gradient(160deg,rgba(18,32,52,.97),rgba(10,20,36,.97));border:1px solid rgba(100,150,220,.3);border-radius:20px;padding:20px 18px;box-shadow:0 20px 50px rgba(0,0,0,.5)}");
  html += F(".brand{display:inline-flex;align-items:center;gap:6px;padding:5px 10px;border-radius:999px;font-size:11px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;background:rgba(87,193,255,.12);border:1px solid rgba(126,215,255,.35);color:#90d8ff;margin-bottom:10px}");
  html += F("h2{margin:4px 0 6px;font-size:20px;font-weight:700;line-height:1.3}");
  html += F(".sub{font-size:12.5px;opacity:.8;line-height:1.5;margin-bottom:14px}");
  html += F(".fgroup{margin-bottom:10px}");
  html += F("label{font-size:11.5px;font-weight:600;opacity:.8;display:block;margin-bottom:4px}");
  html += F("input[type=text],input[type=password]{width:100%;padding:10px 12px;border-radius:10px;border:1.5px solid rgba(100,155,220,.35);background:rgba(8,16,30,.8);color:#f0f7ff;font-size:14px;outline:none;transition:border-color .2s,box-shadow .2s}");
  html += F("input:focus{border-color:#60c8ff;box-shadow:0 0 0 2.5px rgba(96,200,255,.18)}");
  html += F(".pw-wrap{position:relative}");
  html += F(".pw-wrap input{padding-right:40px}");
  html += F(".eye{position:absolute;right:10px;top:50%;transform:translateY(-50%);background:none;border:none;color:#7ab8e0;cursor:pointer;font-size:16px;padding:2px 4px;line-height:1}");
  html += F(".scan-wrap{position:relative}");
  html += F("#ssid-input{padding-right:40px}");
  html += F(".scan-btn{position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;color:#7ab8e0;cursor:pointer;font-size:15px;padding:2px 5px}");
  html += F("#ssid-list{display:none;position:absolute;left:0;right:0;z-index:20;background:#0c1a2e;border:1.5px solid rgba(96,168,240,.4);border-radius:10px;margin-top:3px;max-height:180px;overflow-y:auto;box-shadow:0 8px 24px rgba(0,0,0,.45)}");
  html += F("#ssid-list .net{padding:9px 12px;cursor:pointer;font-size:13px;display:flex;justify-content:space-between;align-items:center;gap:8px}");
  html += F("#ssid-list .net:hover,#ssid-list .net:active{background:rgba(96,180,255,.1)}");
  html += F(".rssi{font-size:11px;opacity:.65}");
  html += F(".lock-ico{font-size:11px;opacity:.6}");
  html += F("button[type=submit]{width:100%;margin-top:6px;padding:12px;border:0;border-radius:12px;background:linear-gradient(135deg,#5ec9ff,#3aa6ff 55%,#4e8fff);color:#021a30;font-weight:800;font-size:14px;letter-spacing:.2px;cursor:pointer;transition:transform .1s,box-shadow .15s;box-shadow:0 4px 16px rgba(60,170,255,.3)}");
  html += F("button[type=submit]:active{transform:translateY(1px);box-shadow:0 2px 8px rgba(60,170,255,.2)}");
  html += F(".info{margin-top:12px;background:rgba(8,18,32,.55);border:1px solid rgba(90,140,210,.22);border-radius:12px;padding:10px 12px;font-size:11.5px;line-height:1.7;color:#b8d4f0}");
  html += F(".info b{color:#d4e9ff}");
  html += F(".foot{font-size:11px;opacity:.7;margin-top:10px;line-height:1.5;text-align:center}");
  html += F("</style></head><body><div class='card'>");
  html += F("<div class='brand'>");
  html += F("<span>&#x1F6F0;</span><span>DROWSY SETUP</span></div>");
  html += F("<h2>WiFi Setup</h2>");
  html += F("<p class='sub'>Connect ESP32 &amp; Raspberry Pi to the same WiFi network.<br>");
  html += F("Kết nối ESP32 và Raspberry Pi vào cùng WiFi.</p>");
  html += F("<form method='post' action='/save'>");
  html += F("<div class='fgroup'>");
  html += F("<label for='ssid-input'>WiFi Name / Tên WiFi</label>");
  html += F("<div class='scan-wrap'>");
  html += F("<input id='ssid-input' name='ssid' type='text' autocomplete='off' autocorrect='off' autocapitalize='none' spellcheck='false' placeholder='Select or type SSID...' required value='");
  html += htmlEscape(_ssid);
  html += F("'>");
  html += F("<button type='button' class='scan-btn' id='scan-btn' title='Scan WiFi'>&#x1F4F6;</button>");
  html += F("<div id='ssid-list'></div></div></div>");
  html += F("<div class='fgroup'>");
  html += F("<label for='pass-input'>Password / Mật khẩu</label>");
  html += F("<div class='pw-wrap'>");
  html += F("<input id='pass-input' name='pass' type='password' autocomplete='current-password' placeholder='Leave blank if open network'>");
  html += F("<button type='button' class='eye' id='eye-btn' title='Show/Hide'>&#x1F441;</button>");
  html += F("</div></div>");
  html += F("<button type='submit'>&#x1F517; Connect &amp; Save</button>");
  html += F("</form>");
  html += F("<div class='info'>");
  html += F("AP: <b>"); html += htmlEscape(_apSsid); html += F("</b><br>");
  html += F("IP: <b>"); html += WiFi.softAPIP().toString(); html += F("</b>");
  if (_ssid.length() > 0) {
    html += F("<br>Saved: <b>"); html += htmlEscape(_ssid); html += F("</b>");
  }
  html += F("</div>");
  html += F("<div class='foot'>After saving, credentials are sent to Raspberry Pi automatically.</div>");
  html += F("</div>");
  html += F("<script>");
  // Eye toggle
  html += F("const eye=document.getElementById('eye-btn'),pi=document.getElementById('pass-input');");
  html += F("if(eye&&pi){eye.addEventListener('click',()=>{pi.type=pi.type==='password'?'text':'password';});}");
  // SSID scan dropdown
  html += F("const si=document.getElementById('ssid-input'),sl=document.getElementById('ssid-list'),sb=document.getElementById('scan-btn');");
  html += F("let scanTimer=null;");
  html += F("function rssiBar(r){if(r>=-55)return '&#x2588;&#x2588;&#x2588;&#x2588;';if(r>=-70)return '&#x2588;&#x2588;&#x2588;&#x2592;';if(r>=-80)return '&#x2588;&#x2588;&#x2592;&#x2592;';return '&#x2588;&#x2592;&#x2592;&#x2592;';}");
  html += F("function showNets(nets){sl.innerHTML='';if(!nets.length){sl.innerHTML='<div class=net style=opacity:.6>No networks found</div>';}");
  html += F("nets.sort((a,b)=>b.r-a.r).forEach(n=>{const d=document.createElement('div');d.className='net';");
  html += F("d.innerHTML='<span>'+n.s+'</span><span><span class=rssi>'+rssiBar(n.r)+'</span>'+(n.e?'<span class=lock-ico> &#x1F512;</span>':'')+'</span>';");
  html += F("d.addEventListener('click',()=>{si.value=n.s;sl.style.display='none';if(n.e)pi.focus();});");
  html += F("sl.appendChild(d);});sl.style.display='block';}");
  html += F("function doScan(retry){fetch('/scan',{cache:'no-store'}).then(r=>r.json()).then(d=>{if(d.scanning){if(retry>0)scanTimer=setTimeout(()=>doScan(retry-1),900);return;}showNets(Array.isArray(d)?d:[]);}).catch(()=>{});}");
  html += F("if(sb){sb.addEventListener('click',()=>{sl.style.display='none';sb.textContent='...';doScan(8);setTimeout(()=>{sb.innerHTML='&#x1F4F6;';},1200);});}");
  html += F("if(si){si.addEventListener('focus',()=>{if(!sl.childNodes.length)doScan(8);});}");
  html += F("document.addEventListener('click',e=>{if(!si.contains(e.target)&&!sl.contains(e.target)&&!sb.contains(e.target))sl.style.display='none';});");
  // Kick off initial scan
  html += F("doScan(8);");
  html += F("</script></body></html>");
  _server.send(200, "text/html", html);
}

void WifiManager::handleSave() {
  String ssid = _server.arg("ssid");
  String pass = _server.arg("pass");
  ssid.trim();
  pass.trim();

  if (ssid.length() == 0) {
    _server.send(400, "text/html",
                 "<!doctype html><html><body style='font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;background:#0a1422;color:#fff;padding:16px'>"
                 "<h3>SSID required / Cần nhập SSID</h3><p>Please go back and enter SSID.<br>Vui lòng quay lại và nhập tên WiFi.</p><a style='color:#7dd3fc' href='/'>Back / Quay lại</a>"
                 "</body></html>");
    return;
  }
  if (ssid.length() > 32) {
    _server.send(400, "text/html",
                 "<!doctype html><html><body style='font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;background:#0a1422;color:#fff;padding:16px'>"
                 "<h3>SSID too long / SSID quá dài</h3><p>SSID max length is 32 characters.<br>Độ dài SSID tối đa là 32 ký tự.</p><a style='color:#7dd3fc' href='/'>Back / Quay lại</a>"
                 "</body></html>");
    return;
  }
  if (pass.length() > 63) {
    _server.send(400, "text/html",
                 "<!doctype html><html><body style='font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;background:#0a1422;color:#fff;padding:16px'>"
                 "<h3>Password too long / Mật khẩu quá dài</h3><p>Password max length is 63 characters.<br>Độ dài mật khẩu tối đa là 63 ký tự.</p><a style='color:#7dd3fc' href='/'>Back / Quay lại</a>"
                 "</body></html>");
    return;
  }

  saveCredentials(ssid, pass);
  _flowState = FLOW_RECONNECT;
  const uint32_t nowMs = millis();
  _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
  _fastRetryLeft = WIFI_FAST_RETRY_ATTEMPTS_SAVE;
  beginConnect(nowMs);
  _lastPiCredEmitMs = nowMs;
  // Allow captive probe success for a short window so OS can auto-close
  // captive view after WiFi is successfully connected.
  _captiveSuccessUntilMs = nowMs + CAPTIVE_SUCCESS_WINDOW_MS;
  _captiveSuccessClientIp = _server.client().remoteIP();

  String html;
  html.reserve(5400);
  html += F("<!doctype html><html><head><meta charset='utf-8'>");
  html += F("<meta name='viewport' content='width=device-width,initial-scale=1'>");
  html += F("<title>Connecting WiFi...</title>");
  html += F("<style>");
  html += F("body{margin:0;min-height:100vh;padding:18px;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 18% 10%,#2c4f7b 0%,#0d1c30 45%,#070d18 100%);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#e8f0ff}");
  html += F(".card{width:min(520px,100%);background:linear-gradient(170deg,rgba(20,35,58,.96),rgba(13,25,43,.96));border:1px solid rgba(120,165,220,.35);border-radius:18px;padding:18px 16px 16px 16px;box-shadow:0 18px 44px rgba(0,0,0,.42)}");
  html += F(".ok{display:inline-block;background:rgba(87,193,255,.15);color:#9fe0ff;border:1px solid rgba(126,215,255,.42);border-radius:999px;padding:6px 10px;font-size:12px;margin-bottom:10px;font-weight:700}");
  html += F("h2{margin:4px 0 8px 0;font-size:22px;line-height:1.26}");
  html += F(".line{font-size:14px;line-height:1.5;margin:8px 0}");
  html += F(".small{font-size:12px;opacity:.88;margin-top:12px;line-height:1.5}");
  html += F(".pulse{display:inline-block;width:9px;height:9px;border-radius:50%;background:#61d2ff;box-shadow:0 0 0 rgba(97,210,255,.75);animation:p 1.2s infinite}");
  html += F("@keyframes p{0%{box-shadow:0 0 0 0 rgba(97,210,255,.75)}70%{box-shadow:0 0 0 12px rgba(97,210,255,0)}100%{box-shadow:0 0 0 0 rgba(97,210,255,0)}}");
  html += F("</style></head><body><div class='card'>");
  html += F("<div class='ok'>Credentials saved / Đã lưu WiFi</div>");
  html += F("<h2>WiFi is connecting... / Đang kết nối WiFi...</h2>");
  html += F("<div class='line'>Target SSID / WiFi đích: <b>");
  html += htmlEscape(ssid);
  html += F("</b></div>");
  html += F("<div class='line' id='state'><span class='pulse'></span> Please wait a few seconds / Vui lòng đợi vài giây.</div>");
  html += F("<div class='small'>Keep this page open. Status will auto-refresh.<br>Giữ trang này mở, trạng thái sẽ tự cập nhật.</div>");
  html += F("</div><script>");
  html += F("const state=document.getElementById('state');");
  html += F("let done=false,ssidMiss=0,authFail=0,closeTicks=0;");
  html += F("function pingProbe(path){const f=document.createElement('iframe');f.style.display='none';f.src=path;document.body.appendChild(f);setTimeout(()=>{try{f.remove();}catch(e){}},1200);}");
  html += F("function tryCloseCna(){");
  html += F("try{window.close();}catch(e){}");
  html += F("try{window.open('','_self');window.close();}catch(e){}");
  html += F("closeTicks++;");
  html += F("if((closeTicks%3)===0){pingProbe('/generate_204?done=1');pingProbe('/hotspot-detect.html?done=1');pingProbe('/library/test/success.html?done=1');}");
  html += F("if(closeTicks===12){try{location.replace('/hotspot-detect.html?done=1');}catch(e){}}");
  html += F("if(closeTicks<14){setTimeout(tryCloseCna,650);} else {state.innerHTML += '<br><br>If popup is still open, tap Done / Neu popup van mo, bam Done.';}}");
  html += F("function finishFlow(msg){");
  html += F("if(done)return;done=true;state.innerHTML=msg;");
  html += F("pingProbe('/hotspot-detect.html');pingProbe('/library/test/success.html');pingProbe('/generate_204');");
  html += F("setTimeout(tryCloseCna,180);}");
  html += F("function nextPoll(ms){setTimeout(poll,ms||1200);}");
  html += F("function poll(){fetch('/status',{cache:'no-store'})");
  html += F(".then(r=>r.json())");
  html += F(".then(s=>{");
  html += F("const piOk=!!s.pi_sync_ok;");
  html += F("if(s.connected){");
  html += F(" finishFlow('Connected / Da ket noi. ESP32 IP: <b>'+s.ip+'</b>'+(piOk?'<br>Pi synced / Pi da dong bo':'<br>Syncing Pi... / Dang dong bo Pi...'));");
  html += F(" return;");
  html += F("}");
  html += F("const flow=((s.flow||'')+'').toUpperCase();");
  html += F("const connecting=!!s.connecting||flow==='STA_CONNECT'||flow==='RECONNECT';");
  html += F("if(piOk){state.textContent='Pi synced ✓. ESP32 still connecting... / Pi da dong bo ✓. ESP32 dang ket noi...';nextPoll(1200);return;}");
  html += F("if(connecting){ssidMiss=0;authFail=0;state.textContent='Connecting to WiFi... / Đang kết nối WiFi...';nextPoll(1200);return;}");
  html += F("if(s.status_code===4){authFail++;if(authFail>=3){state.textContent='Authentication failed / Sai mật khẩu WiFi.';}else{state.textContent='Verifying password... / Đang xác thực mật khẩu...';}nextPoll(1400);return;}");
  html += F("if(s.status_code===1){ssidMiss++;if(ssidMiss>=5){state.textContent='ESP32 cannot find this SSID now. Check 2.4GHz/hidden SSID/signal. / ESP32 chưa thấy WiFi này, kiểm tra băng tần 2.4GHz, SSID ẩn, hoặc sóng yếu.';}else{state.textContent='Scanning WiFi... / Đang quét WiFi...';}nextPoll(1400);return;}");
  html += F("state.textContent='Reconnecting... / Đang thử kết nối lại...';");
  html += F("nextPoll(1200);");
  html += F("})");
  html += F(".catch(()=>{state.textContent='Checking status... / Đang kiểm tra trạng thái...';nextPoll(1600);});}");
  html += F("setTimeout(poll,500);");
  html += F("</script></body></html>");
  _server.send(200, "text/html", html);
}

void WifiManager::handleStatus() {
  JsonDocument doc;
  const uint32_t nowMs = millis();
  doc["connected"] = isConnected();
  doc["connecting"] = (_wifiState == WIFI_CONNECTING);
  doc["portal"] = _portalRunning;
  doc["flow"] = flowStateName(_flowState);
  doc["ssid"] = _ssid;
  doc["ip"] = WiFi.localIP().toString();
  doc["ap_ip"] = WiFi.softAPIP().toString();
  doc["always_on_portal"] = _cfg.alwaysOnPortal;
  doc["status_code"] = static_cast<int>(WiFi.status());
  doc["pi_sync_ok"] = isPiBridgeRecent(nowMs);
  doc["pi_sync_age_ms"] = _lastPiBridgeSeenMs == 0 ? -1 : static_cast<int32_t>(nowMs - _lastPiBridgeSeenMs);

  char payload[384];
  size_t n = serializeJson(doc, payload, sizeof(payload));
  if (n == 0 || n >= sizeof(payload)) {
    _server.send(500, "application/json", "{\"ok\":false,\"error\":\"status_serialize_failed\"}");
    return;
  }
  _server.send(200, "application/json", payload);
}
