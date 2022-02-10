/*
Copyright 2009 Len Popp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

//
// ToyBot
//

// Motor

#include <AFMotor.h>
AF_DCMotor motor(1, MOTOR12_64KHZ); // create motor #1, 64KHz pwm

// I/O Pins

// Analog
#define pinInLight    0
#define pinInTemp     5
// Digital
#define pinInSwitch   (14+2)
#define pinOutLED     (14+3)

// Driving Mode

#define modeStop         0
#define modeBump         1
#define modeToLightInit  2
#define modeToLight      3
#define modeScanLight1   4
#define modeScanLight2   5
#define modeToShadeInit  6
#define modeToShade      7
#define modeScanShade1   8
#define modeScanShade2   9
#define modeSleep        10

int mode = modeStop;

// Timeout

unsigned long tUntil = 0;
unsigned long dtRemain = 0;

// Sensors

int light = 0;
int lightTarget = 0;
#define lightSleepChange 10

long temp = 0;
#define tempHot 29
bool fSleepTempHot = false; // used to set wake-up temp

boolean fSwitch = false;

// Various driving constants

#define dtAccel     300
#define speedAccel  200
#define speedCruise 150
// 120
#define speedSpin   200
#define dtBumpTurn  3000
#define dtScanTurn  7000
#define dtLongDriveTimeout  20000

// Keep count of consecutive short drive segments.
// Lots of short drives means we're either stuck
// or circling around in a good place.
#define dtShortDriveMax  3000
#define nShortDrivesMax  6
unsigned nShortDrives = 0;
unsigned long tDriveStart = 0;

// Flashing LED

#define ledModeOff    0
#define ledModeOn     1
#define ledModeFlash  2

int ledMode = ledModeOff;
unsigned long dtFlashOn = 0;
unsigned long dtFlashOff = 0;
boolean fLEDOn = false;
unsigned long tNextFlash = 0;

void setup()
{
  pinMode(pinInSwitch, INPUT);
  digitalWrite(pinInSwitch, HIGH); // turn on pull-up resistor

  pinMode(pinOutLED, OUTPUT);
  setLEDOff();
  
  // Let's get going!
  awaken();
}

void loop()
{
  // Check for timeout.
  if (tUntil > 0 && millis() >= tUntil) {
    switch (mode) {
      case modeStop:
        break;
      case modeBump:
        // Finished turning. Resume running.
        // TODO: clean up
        // Check the temperature to see what to do.
        if (temp > tempHot)
          startToShade();
        else
          startToLight();
        break;
      case modeToLightInit:
        // Switch from accelerating to cruising speed.
        continueToLight();
        break;
      case modeToLight:
        // Give up driving and look for a better direction.
        startScanLight();
        break;
      case modeScanLight1:
      case modeScanLight2:
        // Can't find a good way to go. Give up and go to sleep for a while.
        sleep();
        break;
      case modeToShadeInit:
        // Switch from accelerating to cruising speed.
        continueToShade();
        break;
      case modeToShade:
        // Give up driving and look for a better direction.
        startScanShade();
        break;
      case modeScanShade1:
      case modeScanShade2:
        // Can't find a good way to go. Give up and go to sleep for a while.
        sleep();
        break;
      case modeSleep:
        // Time to wake up!
        awaken();
        break;
   }
  }
  
  // Read sensors.
  fSwitch = (digitalRead(pinInSwitch) == LOW);
  light = analogRead(pinInLight);
  // For temp sensor, call analogRead() twice with a delay between, to give the
  // ADC input time to settle down after switching inputs.
  // This is only needed for the temp sensor because of its high impedance.
  analogRead(pinInTemp);
  delay(10);
  temp = analogRead(pinInTemp) * 5000L / 1024L  / 10;

  // Check for actions based on sensor readings
  switch (mode) {
    case modeToLightInit:
    case modeToLight:
      // Driving toward light.
      // Check for collision
      if (fSwitch) {
        // Turn around!
        // But first check if we've been stuck for a while.
        if (!checkGiveUpDriving()) {
          reverse();
        }
      } else if (temp > tempHot) {
        // It's too hot for me! Go looking for a cooler spot.
        startScanShade();
      } else {
        // Check if we're in a sunny spot.
        if (light < lightTarget - 10) {
          // Starting to get dimmer. Look for a better direction.
          // But first check if we should give up looking for light.
          if (!checkGiveUpDriving()) {
            startScanLight();
          }
        } else if (light > lightTarget) {
          // reset our brightness target
          lightTarget = light;
        }
      }
      break;
    case modeScanLight1:
      // Scanning in a circle looking for light.
      // Scan until the light gets brighter, then...
      if (light > lightTarget)
        continueScanLight();
      break;
    case modeScanLight2:
      // Scan until light starts to get dimmer again.
      if (light < lightTarget - 3) {
        // Found (close to) the brightest direction.
        // Now move toward the light.
        startToLight();
      } else if (light > lightTarget) {
        // reset our brightness target
        lightTarget = light;
      }
      break;
    case modeToShadeInit:
    case modeToShade:
      // Driving toward shade.
      // Check for collision
      if (fSwitch) {
        // Turn around!
        // But first check if we've been stuck for a while.
        if (!checkGiveUpDriving()) {
          reverse();
        }
      } else if (temp < tempHot) {
        // The temperature has cooled down. Go back into the sun.
        startScanLight();
      } else {
        // Check if we're in a shady spot.
        if (light > lightTarget + 5) {
          // Starting to get brighter. Look for a better direction.
          // But first check if we should give up looking for shade.
          if (!checkGiveUpDriving()) {
            startScanShade();
          }
        } else if (light < lightTarget) {
          // reset our brightness target
          lightTarget = light;
        }
      }
      break;
    case modeScanShade1:
      // Scanning in a circle looking for shade.
      // Scan until the light gets dimmer, then...
      if (light < lightTarget)
        continueScanShade();
      break;
    case modeScanShade2:
      // Scan until light starts to get brighter again.
      if (light > lightTarget + 3) {
        // Found (close to) the dimmest direction.
        // Now move toward the dark side.
        startToShade();
      } else if (light < lightTarget) {
        // reset our brightness target
        lightTarget = light;
      }
      break;
    case modeSleep:
      if (shouldAwaken()) {
        // Woken up by change in light or temperature. Back up & get moving.
        awaken();
      }
      break;
  }

  // Flash LED if necessary
  if (ledMode == ledModeFlash && millis() >= tNextFlash) {
    if (fLEDOn) {
      tNextFlash = millis() + dtFlashOff;
      digitalWrite(pinOutLED, LOW);
      fLEDOn = false;
    } else {      
      tNextFlash = millis() + dtFlashOn;
      digitalWrite(pinOutLED, HIGH);
      fLEDOn = true;
    }
  }
}

void sleep()
{
  // Go to "sleep". Wake up if the light or temperature changes.
  stop(0);
  setLEDFlashing(20, 1980);
  lightTarget = light;
  fSleepTempHot = (temp > tempHot);
  nShortDrives = 0;
  mode = modeSleep;
}

void awaken()
{
  setLEDOff();
  reverse(); // This will get us moving in a different direction, in case we were stuck.
  setLEDFlashing(100, 100);
}

boolean shouldAwaken()
{
  if (light > 300) {
      if (light > lightTarget + 2*lightSleepChange || light < lightTarget - 2*lightSleepChange)
        return true;
  } else {
      if (light > lightTarget + lightSleepChange || light < lightTarget - lightSleepChange)
        return true;
  }
  
  if (fSleepTempHot && temp < tempHot) {
    return true;
  } else if (!fSleepTempHot && temp > tempHot) {
    return true;
  }
  
  return false;
}

void reverse()
{
  setLEDFlashing(250, 250);
  spin(dtBumpTurn);
  mode = modeBump;
}

void startToLight()
{
  setLEDOn();
  // Set the light level we're trying to exceed.
  lightTarget = light;
  // Start accelerating to cruising speed.
  forward(speedAccel, dtAccel);
  mode = modeToLightInit;
  // Keep track of time we start driving.
  tDriveStart = millis();
}

void continueToLight()
{
  // Power down for cruising speed, and set a timeout.
  forward(speedCruise, dtLongDriveTimeout);
  mode = modeToLight;
}

void startScanLight()
{
  setLEDOn();
  // Set the starting light level.
  lightTarget = light;
  // Start spinning, looking for light level to change.
  spin(dtScanTurn);
  mode = modeScanLight1;
}

void continueScanLight()
{
  // We've scanned past the dimmer directions, now look for a brightness peak.
  lightTarget = light;
  // Start spinning, looking for light level to change.
  spin(dtScanTurn);
  mode = modeScanLight2;
}

void startToShade()
{
  setLEDFlashing(250, 750);
  // Set the light level we're trying to stay under.
  lightTarget = light;
  // Start accelerating to cruising speed.
  forward(speedAccel, dtAccel);
  mode = modeToShadeInit;
  // Keep track of time we start driving.
  tDriveStart = millis();
}

void continueToShade()
{
  // Power down for cruising speed, and set a timeout.
  forward(speedCruise, dtLongDriveTimeout);
  mode = modeToShade;
}

void startScanShade()
{
  setLEDFlashing(250, 750);
  // Set the starting light level.
  lightTarget = light;
  // Start spinning, looking for light level to change.
  spin(dtScanTurn);
  mode = modeScanShade1;
}

void continueScanShade()
{
  // We've scanned past the brighter directions, now look for a brightness low point.
  lightTarget = light;
  // Start spinning, looking for light level to change.
  spin(dtScanTurn);
  mode = modeScanShade2;
}

boolean checkGiveUpDriving()
{
  boolean fGiveUp = false;
  if (tDriveStart > 0) {
    unsigned long dt = millis() - tDriveStart;
    if (dt > dtShortDriveMax) {
      // We're cruisin'. Nothing to worry about for now.
      nShortDrives = 0;
    } else if (++nShortDrives > nShortDrivesMax) {
      // Too many short drives. We've been going in small circles.
      // Give up.
      fGiveUp = true;
      sleep();
    }
  }
  return fGiveUp;
}

void stop(unsigned long dt)
{
  if (dt == 0)
    tUntil = 0;
  else
    tUntil = millis() + dt;
  motor.run(RELEASE);
  mode = modeStop;
}

void forward(int nSpeed, unsigned long dt)
{
  tUntil = millis() + dt;
  motor.setSpeed(nSpeed);
  motor.run(FORWARD);
}

void spin(unsigned long dt)
{
  tUntil = millis() + dt;
  motor.setSpeed(speedSpin);
  motor.run(BACKWARD);
}

void setLEDOn()
{
  ledMode = ledModeOn;
  digitalWrite(pinOutLED, HIGH);
  fLEDOn = true;
}

void setLEDOff()
{
  ledMode = ledModeOff;
  digitalWrite(pinOutLED, LOW);
  fLEDOn = false;
}

void setLEDFlashing(unsigned long dtOn, unsigned long dtOff)
{
  dtFlashOn = dtOn;
  dtFlashOff = dtOff;
  ledMode = ledModeFlash;
  tNextFlash = millis() + dtFlashOn;
  digitalWrite(pinOutLED, HIGH);
  fLEDOn = true;
}
