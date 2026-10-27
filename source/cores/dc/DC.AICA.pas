unit DC.AICA;

// AICA in the console: 2 MiB wave RAM shared with the ARM7DI, the sound
// generator/DSP (DC.Sound.AICA, also used by the DSF player), the ARM reset
// control, SH-4 interrupt lines through G2 and the RTC. The ARM and sample
// generator run lazily up to the scheduler clock whenever the SH-4 touches
// AICA state, and at least every 16 samples.
// References: Neill Corlett's AICA notes, KallistiOS g2/spu sources.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, DC.Types, DC.Memory, DC.Scheduler, DC.Interrupts,
  DC.CPU.ARM7, DC.Sound.AICA, DC.GDROM;

const
  AICASampleRate = 44100;
  AICACyclesPerSample = 128; // ARM clocks per output sample, as in the DSF player
  AICAStepSamples = 16;

type
  TDCAICAState = record
    Clock: Int64;          // SH-4 clock of the last generated sample boundary
    Fraction: Int64;       // SH-4 clocks * 44100 accumulated remainder
    Debt: Integer;         // ARM clocks owed
    ARMReset: Boolean;
    RTC: Cardinal;         // seconds since 1950-01-01
    RTCWritable: Boolean;
    RTCSubsecond: Int64;   // SH-4 clocks into the current RTC second
    // SH-4 side interrupt enable/pending (MCIEB/MCIPD).
    MCIEB, MCIPD: Cardinal;
    // Timer bits of the ARM side pending register at the last sync; a rising
    // bit is pending for the SH-4 too.
    TimerPending: Cardinal;
  end;

  TDCAICA = class
  private
    FMemory: TDCMemory;
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FAICA: TAICA;
    FARM: TARM7;
    FSamples: TArray<SmallInt>;
    FSampleCount: Integer;
    function SoundRead(Address: Cardinal): Byte;
    procedure SoundWrite(Address: Cardinal; Value: Byte);
    function ARMRead(Address: Cardinal; Size: Integer): Cardinal;
    procedure ARMWrite(Address, Value: Cardinal; Size: Integer);
    procedure GenerateSample;
    procedure UpdateSH4Interrupt;
    function ReadShared(Reg: Cardinal; out Value: Byte): Boolean;
    function WriteShared(Reg: Cardinal; Value: Byte; FromARM: Boolean): Boolean;
  public
    S: TDCAICAState;
    // CD-DA source mixed into the output (not owned).
    GDROM: TDCGDROM;
    property ARM: TARM7 read FARM;
    property Sound: TAICA read FAICA;
    constructor Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    destructor Destroy; override;
    procedure Reset(RTCSeconds: Cardinal);
    // Generates samples up to the scheduler clock.
    procedure Sync;
    procedure Event;
    function ReadRegister(Offset: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Offset, Value: Cardinal; Size: Integer);
    function ReadRAM(Offset: Cardinal; Size: Integer): Cardinal;
    procedure WriteRAM(Offset, Value: Cardinal; Size: Integer);
    function ReadRTC(Offset: Cardinal): Cardinal;
    procedure WriteRTC(Offset, Value: Cardinal);
    // Stereo samples generated since the last call.
    function TakeSamples: TArray<SmallInt>;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  RegARMReset = $2C00;
  RegMCIEB = $28B4;
  RegMCIPD = $28B8;
  RegMCIRE = $28BC;
  RegSCIPD = $28A0;

constructor TDCAICA.Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
begin
  inherited Create;
  FMemory := Memory;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  FAICA := TAICA.Create(SoundRead, SoundWrite);
  FARM := TARM7.Create(ARMRead, ARMWrite);
  Reset(0);
end;

destructor TDCAICA.Destroy;
begin
  FARM.Free;
  FAICA.Free;
  inherited;
end;

procedure TDCAICA.Reset(RTCSeconds: Cardinal);
begin
  FAICA.Reset;
  FARM.Reset;
  S := Default(TDCAICAState);
  S.Clock := FScheduler.Now;
  S.ARMReset := True;
  S.RTC := RTCSeconds;
  FSampleCount := 0;
  FScheduler.Schedule(TDCEvent.AICA, FScheduler.Now + Int64(AICAStepSamples) * DCCPUClock div AICASampleRate);
end;

function TDCAICA.SoundRead(Address: Cardinal): Byte;
begin
  Result := FMemory.ARAM[Address and (DCARAMSize - 1)];
end;

procedure TDCAICA.SoundWrite(Address: Cardinal; Value: Byte);
begin
  FMemory.ARAM[Address and (DCARAMSize - 1)] := Value;
end;

function TDCAICA.ARMRead(Address: Cardinal; Size: Integer): Cardinal;
begin
  // ARM7 view: wave RAM at 000000, registers at 800000. Aligned wave RAM
  // accesses (most, and every fetch) at once; words rotate as below.
  var Wave := Address and $FFFFFF;
  if Wave < $800000 then
  begin
    Wave := Wave and (DCARAMSize - 1);
    case Size of
      1:
        Exit(FMemory.ARAM[Wave]);
      2:
        if (Wave and 1) = 0 then
          Exit(PWord(FMemory.ARAM + Wave)^);
      4:
        begin
          Result := PCardinal(FMemory.ARAM + (Wave and not Cardinal(3)))^;
          var Bits := Integer(Address and 3) * 8;
          if Bits <> 0 then
            Result := (Result shr Bits) or (Result shl (32 - Bits));
          Exit;
        end;
    end;
  end;
  var Rotate := 0;
  if Size = 4 then
  begin
    Rotate := Integer(Address and 3) * 8;
    Address := Address and $FFFFFFFC;
  end;
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(I)) and $FFFFFF;
    var V: Byte;
    if A < $800000 then
      V := FMemory.ARAM[A and (DCARAMSize - 1)]
    else if A < $808000 then
    begin
      if not ReadShared(A - $800000, V) then
        V := FAICA.ReadRegister(A - $800000);
    end
    else
      V := 0;
    Result := Result or (Cardinal(V) shl (I * 8));
  end;
  if Rotate <> 0 then
    Result := (Result shr Rotate) or (Result shl (32 - Rotate));
end;

procedure TDCAICA.ARMWrite(Address, Value: Cardinal; Size: Integer);
begin
  var Wave := Address and $FFFFFF;
  if Wave < $800000 then
  begin
    Wave := Wave and (DCARAMSize - 1);
    case Size of
      1:
        begin
          FMemory.ARAM[Wave] := Byte(Value);
          Exit;
        end;
      2:
        if (Wave and 1) = 0 then
        begin
          PWord(FMemory.ARAM + Wave)^ := Word(Value);
          Exit;
        end;
      4:
        begin
          PCardinal(FMemory.ARAM + (Wave and not Cardinal(3)))^ := Value;
          Exit;
        end;
    end;
  end;
  if Size = 4 then
    Address := Address and $FFFFFFFC;
  for var I := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(I)) and $FFFFFF;
    var V := Byte(Value shr (I * 8));
    if A < $800000 then
      FMemory.ARAM[A and (DCARAMSize - 1)] := V
    else if A < $808000 then
      if not WriteShared(A - $800000, V, True) then
        FAICA.WriteRegister(A - $800000, V);
  end;
end;

procedure TDCAICA.GenerateSample;
begin
  if not S.ARMReset then
  begin
    Inc(S.Debt, AICACyclesPerSample);
    while S.Debt > 0 do
      Dec(S.Debt, FARM.Step(FAICA.FIQ));
  end;
  // CD-DA enters through the EXT inputs.
  if GDROM <> nil then
  begin
    var CL, CR: SmallInt;
    GDROM.NextSample(CL, CR);
    FAICA.SetExternal(CL, CR);
  end;
  var L, R: SmallInt;
  FAICA.Sample(L, R);
  if FSampleCount + 2 > Length(FSamples) then
    SetLength(FSamples, FSampleCount * 2 + 4096);
  FSamples[FSampleCount] := L;
  FSamples[FSampleCount + 1] := R;
  Inc(FSampleCount, 2);
end;

procedure TDCAICA.Sync;
begin
  // Samples fall on exact multiples of CPUClock/44100 since S.Clock.
  var Elapsed := FScheduler.Now - S.Clock;
  if Elapsed <= 0 then
    Exit;
  var Total := S.Fraction + Elapsed * AICASampleRate;
  var Count := Total div DCCPUClock;
  S.Fraction := Total mod DCCPUClock;
  S.Clock := FScheduler.Now;
  for var I := 1 to Count do
    GenerateSample;
  // RTC seconds.
  Inc(S.RTCSubsecond, Elapsed);
  while S.RTCSubsecond >= DCCPUClock do
  begin
    Dec(S.RTCSubsecond, DCCPUClock);
    Inc(S.RTC);
  end;
  UpdateSH4Interrupt;
end;

procedure TDCAICA.Event;
begin
  Sync;
  FScheduler.Schedule(TDCEvent.AICA, FScheduler.Now + Int64(AICAStepSamples) * DCCPUClock div AICASampleRate);
end;

procedure TDCAICA.UpdateSH4Interrupt;
begin
  // Timer A/B/C overflows (bits 6..8) are pending for both processors.
  var Timers := (Cardinal(FAICA.ReadRegister(RegSCIPD)) or (Cardinal(FAICA.ReadRegister(RegSCIPD + 1)) shl 8)) and $1C0;
  S.MCIPD := S.MCIPD or (Timers and not S.TimerPending);
  S.TimerPending := Timers;
  FInterrupts.SetExternal(HollyExtAICA, (S.MCIEB and S.MCIPD) <> 0);
end;

// Registers both processors see alike: the SH-4 side interrupt enable,
// pending and reset (MCIEB, MCIPD, MCIRE). Either processor may set MCIPD
// bit 5 (the ARM signals the SH-4 with it). The SH-4 sets the ARM side
// SCIPD bit 5 without disturbing the other pending bits.
function TDCAICA.ReadShared(Reg: Cardinal; out Value: Byte): Boolean;
begin
  Result := True;
  var Shift := (Reg and 1) * 8;
  case Reg and $7FFE of
    RegMCIEB:
      Value := Byte(S.MCIEB shr Shift);
    RegMCIPD:
      Value := Byte(S.MCIPD shr Shift);
  else
    Result := False;
  end;
end;

function TDCAICA.WriteShared(Reg: Cardinal; Value: Byte; FromARM: Boolean): Boolean;
begin
  Result := True;
  var Shift := (Reg and 1) * 8;
  case Reg and $7FFE of
    RegMCIEB:
      S.MCIEB := ((S.MCIEB and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift)) and $7FF;
    RegMCIPD:
      S.MCIPD := S.MCIPD or ((Cardinal(Value) shl Shift) and $20);
    RegMCIRE:
      S.MCIPD := S.MCIPD and not (Cardinal(Value) shl Shift);
    RegSCIPD:
      if FromARM then
        Exit(False)
      else if Shift = 0 then
        FAICA.WriteRegister(Reg, FAICA.ReadRegister(Reg) or (Value and $20))
      else
        FAICA.WriteRegister(Reg, FAICA.ReadRegister(Reg));
  else
    Exit(False);
  end;
  UpdateSH4Interrupt;
end;

function TDCAICA.ReadRegister(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Sync;
  Offset := Offset and $7FFF;
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(I)) and $7FFF;
    var V: Byte;
    if (A and $7FFE) = RegARMReset then
      V := Byte((Cardinal(Ord(S.ARMReset)) shr ((A and 1) * 8)) and $FF)
    else if not ReadShared(A, V) then
      V := FAICA.ReadRegister(A);
    Result := Result or (Cardinal(V) shl (I * 8));
  end;
end;

procedure TDCAICA.WriteRegister(Offset, Value: Cardinal; Size: Integer);
begin
  Sync;
  Offset := Offset and $7FFF;
  for var I := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(I)) and $7FFF;
    var V := Byte(Value shr (I * 8));
    case A of
      RegARMReset:
        begin
          var Hold := (V and 1) <> 0;
          if S.ARMReset and not Hold then
          begin
            FARM.Reset;
            S.Debt := 0;
          end;
          S.ARMReset := Hold;
        end;
      RegARMReset + 1:
        ;
    else
      if not WriteShared(A, V, False) then
        FAICA.WriteRegister(A, V);
    end;
  end;
  UpdateSH4Interrupt;
end;

function TDCAICA.ReadRAM(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Sync;
  Offset := Offset and (DCARAMSize - 1);
  case Size of
    1: Result := FMemory.ARAM[Offset];
    2: Result := PWord(FMemory.ARAM + (Offset and not Cardinal(1)))^;
  else
    Result := PCardinal(FMemory.ARAM + (Offset and not Cardinal(3)))^;
  end;
end;

procedure TDCAICA.WriteRAM(Offset, Value: Cardinal; Size: Integer);
begin
  Sync;
  Offset := Offset and (DCARAMSize - 1);
  case Size of
    1: FMemory.ARAM[Offset] := Byte(Value);
    2: PWord(FMemory.ARAM + (Offset and not Cardinal(1)))^ := Word(Value);
  else
    PCardinal(FMemory.ARAM + (Offset and not Cardinal(3)))^ := Value;
  end;
end;

function TDCAICA.ReadRTC(Offset: Cardinal): Cardinal;
begin
  Sync;
  case Offset and $C of
    0: Result := S.RTC shr 16;
    4: Result := S.RTC and $FFFF;
  else
    Result := 0;
  end;
end;

procedure TDCAICA.WriteRTC(Offset, Value: Cardinal);
begin
  Sync;
  case Offset and $C of
    0:
      if S.RTCWritable then
        S.RTC := (S.RTC and $FFFF) or ((Value and $FFFF) shl 16);
    4:
      if S.RTCWritable then
      begin
        S.RTC := (S.RTC and $FFFF0000) or (Value and $FFFF);
        S.RTCSubsecond := 0;
        S.RTCWritable := False;
      end;
    8:
      S.RTCWritable := (Value and 1) <> 0;
  end;
end;

function TDCAICA.TakeSamples: TArray<SmallInt>;
begin
  Result := Copy(FSamples, 0, FSampleCount);
  FSampleCount := 0;
end;

procedure TDCAICA.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  // ARM and sound generator registers: through their public state.
  Archive.Field(FARM.R, SizeOf(FARM.R));
  Archive.Field(FARM.PSR, SizeOf(FARM.PSR));
  Archive.Field(FARM.SPSR, SizeOf(FARM.SPSR));
  FAICA.SerializeState(Archive);
  FARM.SerializeBanks(Archive);
end;

end.
