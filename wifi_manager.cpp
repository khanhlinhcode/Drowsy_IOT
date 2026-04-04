#include "wifi_manager.h"
#include <esp_wifi.h>

WifiManager::WifiManager(const Config& config) : _cfg(config), _server(80) {}

void WifiManager::begin(const char* apPrefix) {
  _apPrefix = String(apPrefix == nullptr ? "DrowsySetup" : apPrefix);
  _lastConnectedMs = millis();
  _wifiState = WIFI_DISCONNECTED;
  _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
  _nextWifiRetryMs = 0;
  _lastInternetCheckMs = 0;

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

  if (hasCredentials()) {
    beginConnect(millis());
  } else {
    startPortal();
  }
}

void WifiManager::tick(uint32_t nowMs) {
  if (_portalRunning) {
    _server.handleClient();
  }

  wl_status_t st = WiFi.status();
  if (st == WL_CONNECTED) {
    if (_wifiState != WIFI_CONNECTED) {
      Serial.println("[WIFI] CONNECTED");
      _lastConnectedMs = nowMs;
      _wifiState = WIFI_CONNECTED;
      _wifiBackoffMs = WIFI_BACKOFF_MIN_MS;
      _nextWifiRetryMs = nowMs;
      _wifiConnectStartMs = 0;
      if (_portalRunning) {
        stopPortal();
      }
    }
    _wasConnected = true;

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

  _wasConnected = false;

  if (_wifiState == WIFI_CONNECTING && (nowMs - _wifiConnectStartMs) > _cfg.connectTimeoutMs) {
    // CRITICAL: break stuck CONNECTING state with timeout.
    Serial.println("[WIFI] TIMEOUT");
    WiFi.disconnect(true, false);
    _wifiState = WIFI_DISCONNECTED;
    _nextWifiRetryMs = nowMs + _wifiBackoffMs;
  }

  if (_wifiState == WIFI_DISCONNECTED && hasCredentials() && nowMs >= _nextWifiRetryMs) {
    beginConnect(nowMs);
  }

  // If disconnected for long time, expose AP portal for reconfiguration.
  if (!_portalRunning) {
    const bool noCreds = !hasCredentials();
    const bool disconnectedLong = (nowMs - _lastConnectedMs) >= _cfg.portalFallbackMs;
    if (noCreds || disconnectedLong) {
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
  _nextWifiRetryMs = millis() + _wifiBackoffMs;
  startPortal();
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

  WiFi.mode(_portalRunning ? WIFI_AP_STA : WIFI_STA);
  WiFi.persistent(true);
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(false);
  // CRITICAL: enforce no WiFi power save during reconnection cycles.
  esp_wifi_set_ps(WIFI_PS_NONE);
  Serial.println("[WIFI] CONNECTING");
  WiFi.begin(_ssid.c_str(), _password.c_str());

  _wifiState = WIFI_CONNECTING;
  _wifiConnectStartMs = nowMs;
  _nextWifiRetryMs = nowMs + _wifiBackoffMs;
  _wifiBackoffMs = min(_wifiBackoffMs * 2U, WIFI_BACKOFF_MAX_MS);
}

bool WifiManager::hasInternet() {
  WiFiClient client;
  client.setTimeout(120);
  const bool ok = client.connect("8.8.8.8", 53);
  if (ok) {
    client.stop();
  }
  return ok;
}

void WifiManager::startPortal() {
  if (_portalRunning) return;

  uint64_t chip = ESP.getEfuseMac();
  char suffix[9];
  snprintf(suffix, sizeof(suffix), "%08X", static_cast<uint32_t>(chip & 0xFFFFFFFFu));
  _apSsid = _apPrefix + "-" + String(suffix);

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(_apSsid.c_str(), _cfg.apPassword);
  _server.begin();
  _portalRunning = true;
}

void WifiManager::stopPortal() {
  if (!_portalRunning) return;
  _server.stop();
  WiFi.softAPdisconnect(true);
  _portalRunning = false;
}

void WifiManager::setupRoutes() {
  _server.on("/", HTTP_GET, [this]() { handleRoot(); });
  _server.on("/save", HTTP_POST, [this]() { handleSave(); });
  _server.on("/save", HTTP_GET, [this]() { handleSave(); });
  _server.on("/status", HTTP_GET, [this]() { handleStatus(); });
}

void WifiManager::handleRoot() {
  String html;
  html.reserve(900);
  html += F("<!doctype html><html><head><meta charset='utf-8'>");
  html += F("<meta name='viewport' content='width=device-width,initial-scale=1'>");
  html += F("<title>WiFi Setup</title>");
  html += F("<style>body{font-family:sans-serif;background:#0e1b2a;color:#e8f0ff;padding:18px}");
  html += F("form{max-width:360px;background:#16263a;padding:16px;border-radius:10px}");
  html += F("input{width:100%;padding:10px;margin:6px 0;border-radius:8px;border:1px solid #2d4a68}");
  html += F("button{width:100%;padding:10px;border:0;border-radius:8px;background:#68b3ff;color:#09223f;font-weight:700}");
  html += F("</style></head><body><h2>ESP32 WiFi Setup</h2>");
  html += F("<p>AP: ");
  html += _apSsid;
  html += F("</p><form method='post' action='/save'>");
  html += F("<input name='ssid' placeholder='WiFi SSID' required>");
  html += F("<input name='pass' placeholder='WiFi Password' type='password'>");
  html += F("<button type='submit'>Save & Connect</button></form>");
  html += F("<p><a href='/status' style='color:#9cc8ff'>Status API</a></p></body></html>");
  _server.send(200, "text/html", html);
}

void WifiManager::handleSave() {
  String ssid = _server.arg("ssid");
  String pass = _server.arg("pass");
  ssid.trim();
  pass.trim();

  if (ssid.length() == 0) {
    _server.send(400, "application/json", "{\"ok\":false,\"error\":\"ssid_required\"}");
    return;
  }

  saveCredentials(ssid, pass);
  beginConnect(millis());

  _server.send(200, "application/json", "{\"ok\":true,\"message\":\"saved\"}");
}

void WifiManager::handleStatus() {
  String body;
  body.reserve(240);
  body += F("{\"connected\":");
  body += (isConnected() ? F("true") : F("false"));
  body += F(",\"portal\":");
  body += (_portalRunning ? F("true") : F("false"));
  body += F(",\"ssid\":\"");
  body += _ssid;
  body += F("\",\"ip\":\"");
  body += WiFi.localIP().toString();
  body += F("\"}");
  _server.send(200, "application/json", body);
}
