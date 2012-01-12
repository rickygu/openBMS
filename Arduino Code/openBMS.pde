#include <Spi.h>
#include <SoftwareSerial.h>

// X-BMS Controller Software Version 1.10
// LTC6802-2 in addressable mode

//For UBCECC E-Beetle 
// 32 Cell LiFePO4 480AH Thundersky
// 3 x daughter board with address set at 0000 / 0001 / 0010


// Written by Ricky Gu 

//March 5 11

// BMS Settings
#define BOTTOMSTACK   0x80 // bottom bms board address 0000
#define TOPSTACK      0x82 // set bms to 3 daughter boards with top of stack address of 0010
#define TOTALCELLS    32   // Set total cell number to 32
#define TOTALBOARDS   3    // set total board number to 3
#define HIGHVOLTAGECUTOFF 3.7  // Define high voltage cut off
#define LOWVOLTAGEWARNING 2.8  // Define low voltage warning
#define LOWVOLTAGECUTOFF 2.55   // Define low voltage cut off
#define VOLTAGEALLOWANCE 0.009 // Define the accuracy the balancing algorithm can balance it to.
#define CURRENTSENSOR 0 //Define the pin which the current sensor reading is in
#define DELTASIGMAFACTOR 30 //define delta sigma adc factor
#define ADCREFERENCEVOLTAGE 3.3 //use external adc reference voltage of 3.3v
#define CHARGERSHUTOFF 8
#define BATTERYSHUTOFF 9
#define GENERALRELAY 7
#define CHARGERRESTARTVOLTAGE 3.5
#define LCDPIN 3
#define RESETPIN 2 
#define HIVOLTAGESHUNT 3.5
// Definition of all constants

#define TALK digitalWrite(SS_PIN, LOW); // Chip Select
#define DONE digitalWrite(SS_PIN, HIGH); // Chip Deselect


// LTC6802-2 Command Codes 

#define WRCFG  0x01  // Write Configuration Registers
#define RDCFG  0x02  // Read Configuration 
#define RDCV   0x04  // Read Cell Voltages without discharge

#define RDFLG  0x06  // Read Flags
#define RDTMP  0x08  // Read Temps

#define STCVAD 0x10  // Start all A/D's - Poll Status
#define STCVDC 0x60  // A/D Conversions and Poll Status, with Discharge Permitted
#define STOWAD 0x20  // Start testing all open wire - poll status
#define STTMPAD 0x30 // Start temperature A/D's - Poll Status


// Function Declaration
void wakeUp();
void readVolts();
float vTotal();
float vAvg();
int highestCell();
int lowestCell();
void balanceCells();
void writeConfig();
void readCurrent();
void selectLineOne();
void selectLineTwo();
void clearLCD();
void goTo(int position);
void updateServer();

// Variable declaration 
byte ltcResponse[20];
float voltage[12*TOTALBOARDS+1];
float cellVoltage[TOTALCELLS+1];
int evenCell;
int intTemp;
byte byteTemp;
byte address;
float voltageTotal;
float voltageAverage;
float voltageHighest;
float voltageLowest;
int highestCellNumber;
int lowestCellNumber;
boolean isCellTooHigh;
boolean isCellTooLow;
boolean isCellWayTooLow;
byte CFGR1 = 0;
byte CFGR2 = 0;
int cellToSend;
int zeroReference;
int instantCurrent;
SoftwareSerial LCD = SoftwareSerial(0, LCDPIN);  
int LCDvoltage;
int LCDlowcell;
int LCDhighcell; 
double mVhighest;
double mVlowest; 
float watt;
float wattHour;
unsigned long previousTime;
unsigned long currentTime;
float deltaTime;
boolean reset;
int regen;
int isChargingCounter;
int isCharging;
boolean printLCD;
long Wh;
int Percent;


void setup()
{
  // SPI configuration
  // No interupt, Enable SPI, MSB first, Master, Clock rests high
  // read on rising edge, 1mhz speed

  DONE // Set CS High
  pinMode(RESETPIN, INPUT);
  digitalWrite(RESETPIN, HIGH);
  pinMode(CHARGERSHUTOFF, OUTPUT);
  pinMode(BATTERYSHUTOFF, OUTPUT);
  pinMode(GENERALRELAY, OUTPUT);
  Spi.mode ((1<<SPE) | (1<<MSTR) | (1<<CPOL) | (1 << CPHA)| (1 << SPR1) | (1<<SPR0) );
  Serial.begin(9600);
  //Serial.print("\e[2J");
  zeroReference = 0;
  analogReference(EXTERNAL);
  for(int i = 0; i < DELTASIGMAFACTOR; i ++)
  {
    zeroReference = zeroReference + analogRead(CURRENTSENSOR);
  }
  zeroReference = zeroReference/DELTASIGMAFACTOR;
  pinMode(LCDPIN, OUTPUT);
  LCD.begin(9600);
  clearLCD();
  wattHour  = 0;
  previousTime = 0;
  currentTime= 0;
  isChargingCounter = 0;
  isCharging = 0;
  // lcdPrint = true;
}


void loop(){
  //reset e-meter
  reset = digitalRead(RESETPIN);
  if(reset == LOW)
  {
    wattHour = 0;
    clearLCD();
  }

  // Start A-D, Read Current (not implemented yet), Save voltages into cellVoltage Array
  //wakeUp();

  readVolts();

  // Read Current Transducer
  readCurrent();

  // calculate total and average voltage of battery pack
  voltageTotal = vTotal();
  voltageAverage = voltageTotal / TOTALCELLS;

  //calculate power and record energy useage
  watt = voltageTotal * instantCurrent;
  previousTime = currentTime;
  currentTime = millis();
  deltaTime = (currentTime - previousTime);

  wattHour = wattHour + watt*deltaTime/3600000;
  Wh = (long) wattHour;

  //Serial.print(deltaTime);

  Serial.print("Total Voltage:");
  Serial.print(voltageTotal);
  Serial.print("   Average V");
  Serial.println(voltageAverage);
  

  // Locate the highest voltage cell number. Highest voltage cell value located in float voltageHighest

  highestCellNumber = highestCell();
  /*
Serial.print("highest cell: ");
   Serial.print(highestCellNumber);
   Serial.print(" is ");
   Serial.print(voltageHighest);
   Serial.println(" V");
   */


  // is cell higher than high voltage cutoff?

  if(voltageHighest >= HIGHVOLTAGECUTOFF)
  {
    isCellTooHigh = true; 
    digitalWrite(CHARGERSHUTOFF, HIGH);
  }
  else
  {
    isCellTooHigh = false;
    if(voltageHighest < CHARGERRESTARTVOLTAGE)
    {
      digitalWrite(CHARGERSHUTOFF, LOW);
    }
  }

  // locate the lowest voltage cell

  lowestCellNumber = lowestCell();

  /*
Serial.print("lowest cell: ");
   Serial.print(lowestCellNumber);
   Serial.print(" is ");
   Serial.print(voltageLowest);
   Serial.println(" V");
   */
  //Check if it's charging
  if(instantCurrent < 0)
  {
    isChargingCounter++;
  }
  else
  {
    isChargingCounter = 0;
  }

  if(isChargingCounter > 300)
  {
    isCharging = 1;
  }
  else
  {
    isCharging = 0;
  }

  if (printLCD = true)
  {
    selectLineOne();
    //LCD.print("V:");
    //LCDvoltage = (int) voltageTotal;
    //LCD.print(LCDvoltage);
    LCD.print("E:");
    LCD.print(Wh);
    LCD.print(" ");
    goTototal(9);
    LCD.print(" A:");
    LCD.print(instantCurrent);
    LCD.print("  ");
    selectLineTwo();
    mVlowest = voltageLowest *100;
    LCDlowcell = (int)mVlowest;
    LCD.print("L");
    LCD.print(lowestCellNumber);
    LCD.print(':');
    LCD.print(LCDlowcell);
    goTo(24);
    LCD.print(" H");
    LCD.print(highestCellNumber);
    LCD.print(':');
    mVhighest = voltageHighest*100;
    LCDhighcell = (int) mVhighest;
    LCD.print(LCDhighcell);
    printLCD = !printLCD;
  }

  // is this cell lower than 3.0V? if so warn driver

  if(voltageLowest < LOWVOLTAGEWARNING)
  {
    isCellTooLow = true;
    //warn driver here
    // is this cell lower than 2.8v? cut battery pack if kwh remaining is under 3kwh. 

    if(voltageLowest < LOWVOLTAGECUTOFF)
    {
      isCellWayTooLow = true;
      if(instantCurrent < 30)
      {
        digitalWrite(BATTERYSHUTOFF, HIGH);
      }
      //Serial.print("cell too low");
      //digitalWrite(BATTERYSHUTOFF, HIGH);
      //Check Kwh and cut battery pack here
    }
    else
    {
      isCellWayTooLow = false;
    }
  }
  else
  {
    isCellTooLow = false;
    // find cells that are above the lowest voltage cell by the defined VOLTAGEALLOWANCE value. 


  }

  // turn on shunt resistors on the cells that are 0.05v higher than the average
  // turn off the rest
  balanceCells();

  // display data on LCD

  // send data to web server



}

void wakeUp()
{
  TALK
    Spi.transfer(0x01);   // Command Set
  Spi.transfer(0xE2);   // Command Wake up
  Spi.transfer(CFGR1);   // Command
  Spi.transfer(CFGR2);   // Command
  Spi.transfer(0x00);   // Command
  Spi.transfer(0x00);   // Command
  Spi.transfer(0x00);   // Command
  DONE
}
void readVolts()
{
  // Broadcast Command, start A-D
  TALK
    Spi.transfer(STCVAD);
  //delay(20); // wait 20ms for all the boards to read ADC (use this delay time to read current)
  //send cell voltage to fill delay


  //ansi escape code to clear screen
  //Serial.println("\e[0;0H");
  if(Serial.available() > 0)
  {
    updateServer();
  }
  else
  {
    delay(20);
  }

  DONE

    address = BOTTOMSTACK;

  for(int boardNumber = 0; boardNumber < TOTALBOARDS; boardNumber++)
  {
    //Serial.print("address:");
    //Serial.println(address, HEX);
    // Read 18 byte from 1 board and then increment address to read the next
    TALK
      Spi.transfer(address);
    Spi.transfer(RDCV);
    for(int i=0; i<19; i++)
      ltcResponse[i] = Spi.transfer(RDCV);   // send command to read voltage registers
    DONE

      for (int i=1; i<=12; i++)
    {
      int x = i + 12*boardNumber; 
      //Serial.println(x);
      if(i == 1)
      {
        byteTemp = ltcResponse[1] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[0] + (intTemp << 4);
      }
      if(i== 2)
      {
        byteTemp = ltcResponse[1] >> 4;
        intTemp = (int)ltcResponse[2];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
      if(i == 3)
      {
        byteTemp = ltcResponse[4] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[3] + (intTemp << 4);
      }
      if(i== 4)
      {
        byteTemp = ltcResponse[4] >> 4;
        intTemp = (int)ltcResponse[5];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
      if(i == 5)
      {
        byteTemp = ltcResponse[7] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[6] + (intTemp << 4);
      }
      if(i== 6)
      {
        byteTemp = ltcResponse[7] >> 4;
        intTemp = (int)ltcResponse[8];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
      if(i == 7)
      {
        byteTemp = ltcResponse[10] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[9] + (intTemp << 4);
      }
      if(i== 8)
      {
        byteTemp = ltcResponse[10] >> 4;
        intTemp = (int)ltcResponse[11];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
      if(i == 9)
      {
        byteTemp = ltcResponse[13] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[12] + (intTemp << 4);
      }
      if(i== 10)
      {
        byteTemp = ltcResponse[13] >> 4;
        intTemp = (int)ltcResponse[14];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
      if(i == 11)
      {
        byteTemp = ltcResponse[16] << 4;
        intTemp = (int)byteTemp;
        voltage[x] = ltcResponse[15] + (intTemp << 4);
      }
      if(i== 12)
      {
        byteTemp = ltcResponse[16] >> 4;
        intTemp = (int)ltcResponse[17];
        intTemp = intTemp << 4;
        voltage[x] = intTemp + byteTemp;
      }
    }
    //Serial.print("Board Number:");
    //Serial.println(boardNumber);
    address++;
  }
  //decode register into voltage values. 
  for(int i = 1; i <= TOTALCELLS; i++)
  {
    cellVoltage[i] = voltage[i] * 1.5 / 1000;
    //if(instantCurrent > 10)
    //cellVoltage[5] += instantCurrent*0.0015;
    /*
      Serial.print("C");
     Serial.print(i);
     //Serial2.println(i);
     Serial.print(": ");
     Serial.print(cellVoltage[i]);
     Serial.print(";  ");
     //Serial2.println(cellVoltage[i]);
     */
    /*
      if(i == 6) Serial.println(' ');
     if(i == 12) Serial.println(' ');
     if(i == 18) Serial.println(' ');
     if(i == 24) Serial.println(' ');
     if(i == 30) Serial.println(' ');
     */
  }
  //Serial.println(' ');
}

float vTotal(){
  float total = 0;
  for (int i = 1; i <= TOTALCELLS; i++){
    total = total + cellVoltage[i];
  }
  return total;
}

int highestCell()
{
  voltageHighest = 0;
  int cellNumber;
  for (int i = 1; i <= TOTALCELLS; i++)
  {
    if (cellVoltage[i] > voltageHighest)
    {
      voltageHighest = cellVoltage[i];
      cellNumber = i;
    }
  }
  return cellNumber;
}

int lowestCell()
{
  voltageLowest = 99;
  int cellNumber;
  for(int i = 1; i <= TOTALCELLS; i++)
  {
    if (cellVoltage [i] < voltageLowest)
    {
      voltageLowest = cellVoltage[i];
      cellNumber = i;
    }
  }
  return cellNumber;
}

void balanceCells()
{
  CFGR1 = 0x00;
  CFGR2 = 0x00;
  byte temp;
  int x;
  address = BOTTOMSTACK;
  float difference[TOTALCELLS];

  //find difference and save in an array
  for(int i = 1; i<= TOTALCELLS; i++)
  {
    difference[i] = cellVoltage[i] - HIVOLTAGESHUNT;
    /*
      Serial.print("cell");
     Serial.print(i);
     Serial.print("difference is: ");
     Serial.println(difference[i]);
     */
  }

  for(int boardNumber = 0; boardNumber < TOTALBOARDS; boardNumber++)
  {
    CFGR1 = 0x00;
    CFGR2 = 0x00;
    if(isCellTooLow == true)
    {
      CFGR1 = 0x00;
      CFGR2 = 0x00;       
    }
    else
    {
      for(int i = 1; i <= 12; i++) 
      {
        int cellNumber = i + (boardNumber*12);
        if(i <= 8)
        {
          if(difference[cellNumber] > VOLTAGEALLOWANCE)
          {
            x = i - 1; // calculate position to shift
            temp = 0x01;
            temp = temp << x;
            CFGR1 = CFGR1 + temp; // bitwise or
            /*
                  Serial.print("Cell ");
             Serial.print(cellNumber);
             Serial.print("should be shunt");
             Serial.print("CFGR1 is");
             Serial.println(CFGR1, HEX);
             */
          }
        }
        else
        {
          if(difference[cellNumber] > VOLTAGEALLOWANCE)
          {
            x = i - 9;
            temp = 0x01;
            temp = temp << x;
            CFGR2 = CFGR2 + temp;
            /*
                  Serial.print("Cell ");
             Serial.print(cellNumber);
             Serial.print("should be shunt");
             Serial.print("CFGR2 is");
             Serial.println(CFGR2, HEX);
             */
          }
        }
      }
    }
    writeConfig();
    address++;

  }

}

void writeConfig()
{
  TALK
    Spi.transfer(address);   // Command addresss
  Spi.transfer(0x01);   // Commandwrite CRG
  Spi.transfer(0x01);   // WRITE CFGR0 
  Spi.transfer(CFGR1);   // WRITE CFGR1 
  Spi.transfer(CFGR2);   // WRITE CFGR2
  Spi.transfer(0x00);   // WRITE CFGR3
  Spi.transfer(0x00);   // WRITE CFGR4
  Spi.transfer(0x00);   // WRITE CFGR5
  DONE
}

void readCurrent()
{
  int adc = 0;
  analogReference(EXTERNAL);
  for(int i = 0; i < DELTASIGMAFACTOR; i++)
  {
    adc = adc + analogRead(CURRENTSENSOR);
  }
  adc = adc/DELTASIGMAFACTOR;
  //calculation forumla based on LEM HASS 600-S Current Transducer
  instantCurrent = (adc-zeroReference)*(ADCREFERENCEVOLTAGE/1024)*600/0.625;
  int absCurrent;
  absCurrent = abs(instantCurrent);
  if(absCurrent < 4)
    instantCurrent = 0;

  Serial.print("Current: ");
  Serial.print(instantCurrent);
  Serial.println("Amps");

}

void selectLineOne(){  //puts the cursor at line 0 char 0.
  LCD.print(0xFE, BYTE);   //command flag
  LCD.print(128, BYTE);    //position
}
void selectLineTwo(){  //puts the cursor at line 0 char 0.
  LCD.print(0xFE, BYTE);   //command flag
  LCD.print(192, BYTE);    //position
}
void clearLCD(){
  LCD.print(0xFE, BYTE);   //command flag
  LCD.print(0x01, BYTE);   //clear command.
}
void goTo(int position) { //position = line 1: 0-15, line 2: 16-31, 31+ defaults back to 0
  if (position<16){ 
    LCD.print(0xFE, BYTE);   //command flag
    LCD.print((position+128), BYTE);    //position
  }
  else if (position<32){
    LCD.print(0xFE, BYTE);   //command flag
    LCD.print((position+48+128), BYTE);    //position 
  } 
  else { 
    goTo(0); 
  }
}

void updateServer()
{
  if(Serial.available() > 0)
  {
    cellToSend = Serial.read();
    if(cellToSend == 0)
    {
      Serial.print(wattHour);
    }
    if(cellToSend == 1)
    {
      Serial.print(voltageTotal);
    }
    if(cellToSend == 2)
    {
      Serial.print(instantCurrent);
    }
    if(cellToSend == 3)
    {
      if(instantCurrent < 0)
      {
        regen = abs(instantCurrent);
        Serial.print(regen);
      }
      else
      {
        Serial.print('0');
      }
    }
    if(cellToSend == 4)
    {
      Serial.print(isCharging);
    }

    if(cellToSend >3)
    {
      Serial.print(cellVoltage[cellToSend-4]);
      Serial.flush();
    }
  }
}


