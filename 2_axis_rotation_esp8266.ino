#include <AccelStepper.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>

#include <math.h>

// ==================================================
// Wi-Fi
// ==================================================

const char *WIFI_SSID = "Excitel_LOST";
const char *WIFI_PASSWORD = "4815162342";

ESP8266WebServer server(80);


// ==================================================
// Motor wiring
// ==================================================

// Motor 1: bottom axis
#define M1_STEP D1
#define M1_DIR D2

// Motor 2: top axis
#define M2_STEP D5
#define M2_DIR D6

AccelStepper motor1(AccelStepper::DRIVER, M1_STEP, M1_DIR);
AccelStepper motor2(AccelStepper::DRIVER, M2_STEP, M2_DIR);


// ==================================================
// Motion limits and tuning
// ==================================================

constexpr float MICROSTEPS_PER_REV = 6400.0f; // 200 * 32
constexpr float STEPS_PER_DEGREE = MICROSTEPS_PER_REV / 360.0f;
constexpr float MAX_AXIS_DEGREES = 160.0f;
constexpr long MAX_AXIS_STEPS = lroundf(MAX_AXIS_DEGREES * STEPS_PER_DEGREE);

constexpr float DEFAULT_MAX_SPEED = 2200.0f;
constexpr float DEFAULT_ACCELERATION = 1400.0f;
constexpr float MIN_PULSE_WIDTH_US = 5.0f;

// If one axis moves the opposite way from expectation,
// flip these booleans before changing wiring.
constexpr bool MOTOR1_DIR_INVERTED = false;
constexpr bool MOTOR2_DIR_INVERTED = false;


// ==================================================
// Logical state
// ==================================================

struct AxisState {
  float targetDegrees = 0.0f;
  float currentDegrees = 0.0f;
  long targetSteps = 0;
  long currentSteps = 0;
};

AxisState axis1;
AxisState axis2;


// ==================================================
// Helpers
// ==================================================

long degreesToSteps(float degrees) {
  return lroundf(degrees * STEPS_PER_DEGREE);
}

float stepsToDegrees(long steps) {
  return steps / STEPS_PER_DEGREE;
}

float clampDegrees(float degrees) {
  if (degrees > MAX_AXIS_DEGREES) {
    return MAX_AXIS_DEGREES;
  }
  if (degrees < -MAX_AXIS_DEGREES) {
    return -MAX_AXIS_DEGREES;
  }
  return degrees;
}

long clampSteps(long steps) {
  if (steps > MAX_AXIS_STEPS) {
    return MAX_AXIS_STEPS;
  }
  if (steps < -MAX_AXIS_STEPS) {
    return -MAX_AXIS_STEPS;
  }
  return steps;
}

float readArgFloat(const char *name, float fallback) {
  if (!server.hasArg(name)) {
    return fallback;
  }

  return server.arg(name).toFloat();
}

String jsonFloat(float value, int precision = 2) {
  return String(value, precision);
}

void syncAxisState(AxisState &axis, AccelStepper &stepper) {
  axis.currentSteps = stepper.currentPosition();
  axis.currentDegrees = stepsToDegrees(axis.currentSteps);
  axis.targetSteps = stepper.targetPosition();
  axis.targetDegrees = stepsToDegrees(axis.targetSteps);
}

void applyTargets(float motor1Degrees, float motor2Degrees) {
  axis1.targetDegrees = clampDegrees(motor1Degrees);
  axis2.targetDegrees = clampDegrees(motor2Degrees);

  axis1.targetSteps = clampSteps(degreesToSteps(axis1.targetDegrees));
  axis2.targetSteps = clampSteps(degreesToSteps(axis2.targetDegrees));

  motor1.moveTo(axis1.targetSteps);
  motor2.moveTo(axis2.targetSteps);
}

String buildStateJson(const String &message) {
  syncAxisState(axis1, motor1);
  syncAxisState(axis2, motor2);

  String json;
  json.reserve(512);
  json += "{";
  json += "\"ok\":true";
  json += ",\"message\":\"" + message + "\"";
  json += ",\"wifiSsid\":\"" + String(WIFI_SSID) + "\"";
  json += ",\"ip\":\"" + WiFi.localIP().toString() + "\"";
  json += ",\"uptimeMs\":" + String(millis());
  json += ",\"motor1\":{";
  json += "\"currentDeg\":" + jsonFloat(axis1.currentDegrees);
  json += ",\"targetDeg\":" + jsonFloat(axis1.targetDegrees);
  json += ",\"currentSteps\":" + String(axis1.currentSteps);
  json += ",\"targetSteps\":" + String(axis1.targetSteps);
  json += "}";
  json += ",\"motor2\":{";
  json += "\"currentDeg\":" + jsonFloat(axis2.currentDegrees);
  json += ",\"targetDeg\":" + jsonFloat(axis2.targetDegrees);
  json += ",\"currentSteps\":" + String(axis2.currentSteps);
  json += ",\"targetSteps\":" + String(axis2.targetSteps);
  json += "}";
  json += "}";
  return json;
}

void sendJson(int statusCode, const String &json) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(statusCode, "application/json", json);
}


// ==================================================
// HTTP handlers
// ==================================================

void handleRoot() {
  String html;
  html.reserve(512);
  html += "<!doctype html><html><head><meta charset='utf-8'>";
  html += "<meta name='viewport' content='width=device-width,initial-scale=1'>";
  html += "<title>Veya</title></head><body style='font-family:system-ui;padding:24px'>";
  html += "<h1>Veya ESP8266</h1>";
  html += "<p>Use <code>/health</code>, <code>/move</code>, <code>/jog</code>, <code>/zero</code>, and <code>/state</code>.</p>";
  html += "</body></html>";
  server.send(200, "text/html", html);
}

void handleHealth() {
  sendJson(200, buildStateJson("healthy"));
}

void handleState() {
  sendJson(200, buildStateJson("state"));
}

void handleZero() {
  motor1.setCurrentPosition(0);
  motor2.setCurrentPosition(0);

  axis1.targetDegrees = 0.0f;
  axis2.targetDegrees = 0.0f;
  axis1.targetSteps = 0;
  axis2.targetSteps = 0;

  sendJson(200, buildStateJson("zeroed"));
}

void handleMove() {
  const float motor1Degrees = readArgFloat("m1", axis1.targetDegrees);
  const float motor2Degrees = readArgFloat("m2", axis2.targetDegrees);

  applyTargets(motor1Degrees, motor2Degrees);
  sendJson(200, buildStateJson("moving"));
}

void handleJog() {
  const float delta1 = readArgFloat("dm1", 0.0f);
  const float delta2 = readArgFloat("dm2", 0.0f);

  applyTargets(axis1.targetDegrees + delta1, axis2.targetDegrees + delta2);
  sendJson(200, buildStateJson("jogging"));
}

void handlePreset() {
  const String preset = server.hasArg("name") ? server.arg("name") : String();

  if (preset == "home") {
    applyTargets(0.0f, 0.0f);
    sendJson(200, buildStateJson("preset:home"));
    return;
  }

  if (preset == "look_up") {
    applyTargets(0.0f, 70.0f);
    sendJson(200, buildStateJson("preset:look_up"));
    return;
  }

  if (preset == "yes") {
    applyTargets(axis1.targetDegrees, clampDegrees(axis2.targetDegrees + 10.0f));
    sendJson(200, buildStateJson("preset:yes"));
    return;
  }

  if (preset == "no") {
    applyTargets(clampDegrees(axis1.targetDegrees + 10.0f), axis2.targetDegrees);
    sendJson(200, buildStateJson("preset:no"));
    return;
  }

  sendJson(400, "{\"ok\":false,\"message\":\"unknown preset\"}");
}

void handleNotFound() {
  sendJson(404, "{\"ok\":false,\"message\":\"not found\"}");
}


// ==================================================
// Setup / loop
// ==================================================

void setup() {
  Serial.begin(115200);
  delay(200);

  motor1.setMaxSpeed(DEFAULT_MAX_SPEED);
  motor1.setAcceleration(DEFAULT_ACCELERATION);
  motor1.setMinPulseWidth(MIN_PULSE_WIDTH_US);

  motor2.setMaxSpeed(DEFAULT_MAX_SPEED);
  motor2.setAcceleration(DEFAULT_ACCELERATION);
  motor2.setMinPulseWidth(MIN_PULSE_WIDTH_US);

  motor1.setPinsInverted(MOTOR1_DIR_INVERTED, false, false);
  motor2.setPinsInverted(MOTOR2_DIR_INVERTED, false, false);

  motor1.setCurrentPosition(0);
  motor2.setCurrentPosition(0);
  applyTargets(0.0f, 0.0f);

  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print("Connecting to Wi-Fi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("Connected. IP: ");
  Serial.println(WiFi.localIP());

  server.on("/", HTTP_GET, handleRoot);
  server.on("/health", HTTP_GET, handleHealth);
  server.on("/state", HTTP_GET, handleState);
  server.on("/zero", HTTP_POST, handleZero);
  server.on("/zero", HTTP_GET, handleZero);
  server.on("/move", HTTP_POST, handleMove);
  server.on("/move", HTTP_GET, handleMove);
  server.on("/jog", HTTP_POST, handleJog);
  server.on("/jog", HTTP_GET, handleJog);
  server.on("/preset", HTTP_POST, handlePreset);
  server.on("/preset", HTTP_GET, handlePreset);
  server.onNotFound(handleNotFound);

  server.begin();
}

void loop() {
  server.handleClient();

  motor1.run();
  motor2.run();

  yield();
}
