unit NES.Mapper.Cnrom;

interface

uses
  NES.State, NES.Types, NES.Mapper, Core.Storage, NES.Audio.Recordings;

type
  TMapperCnrom = class(TMapper)
  private
    FPrgRom, FChrMemory: TByteArray;
    FHasChrRam: Boolean;
    FBusConflicts: Boolean;
    FMirrorMode: TMirrorMode;
    FChrBank: UInt8;
    FPrgRam: array[0..$1FFF] of UInt8;
    FPrgRamSize, FPrgReadMask, FChrBankCount, FChrOffset: Integer;
    procedure SelectChrBank(Value: UInt8);
  public
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ConfigurePrgRam(Size: UInt64);
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; BusConflicts: Boolean = True; PrgRamEnabled: Boolean = False);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure Reset; override;
  end;

  TMapperAerobicsStudio = class(TMapperCnrom)
  private
    type
      TPlayback = packed record
        SyncHigh, Active: Boolean;
        MessageIndex: Byte;
        Phase, Position: Integer;
        Sample: SmallInt;
      end;

      TSpeechStart = packed record
        InputTrack, OutputTrack: Byte;
        CyclesToLatch, CyclesToOutput: Integer;
      end;
  private
    FSpeech: TPlayback;
    FSpeechStart: TSpeechStart;
    FRecordings: TNesSpeechRecordings;
    FCpuHz, FSyncPulseCycles, FSpeechDelayCycles: Integer;
    procedure StartSpeech;
  public
    constructor Create(const Prg, Chr: NES.Types.TByteArray; MirrorMode: TMirrorMode);
    procedure LoadRecordings(const Storage: IStorage; const RomName: string);
    procedure Reset; override;
    procedure SetRegion(Region: TNesRegion); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

implementation

uses
  System.Classes, NES.Consts;

procedure TMapperCnrom.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FChrBank, SizeOf(FChrBank));
  if State.Loading then
    SelectChrBank(FChrBank);
  if State.Version >= 6 then
    State.Field(FPrgRam, SizeOf(FPrgRam))
  else if State.Loading then
    FillChar(FPrgRam, SizeOf(FPrgRam), 0);
end;

constructor TMapperCnrom.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; BusConflicts: Boolean; PrgRamEnabled: Boolean);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  FBusConflicts := BusConflicts;
  if PrgRamEnabled then
    ConfigurePrgRam(SizeOf(FPrgRam));
  FMirrorMode := AMirrorMode;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  FChrBankCount := Length(FChrMemory) div $2000;
  FPrgReadMask := $7FFF;
  if Length(FPrgRom) = $4000 then
    FPrgReadMask := $3FFF;
  Reset;
end;

procedure TMapperCnrom.ConfigurePrgRam(Size: UInt64);
begin
  if Size > SizeOf(FPrgRam) then
    Size := SizeOf(FPrgRam);
  FPrgRamSize := Integer(Size);
end;

procedure TMapperCnrom.SelectChrBank(Value: UInt8);
begin
  FChrBank := Value;
  FChrOffset := (Integer(Value) mod FChrBankCount) * $2000;
end;

function TMapperCnrom.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FPrgRamSize <> 0) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FPrgRam[(Address and $1FFF) mod FPrgRamSize];
    Exit(True);
  end;
  Result := Address >= $8000;
  if Result then
    Value := FPrgRom[Address and FPrgReadMask];
end;

function TMapperCnrom.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address >= $8000 then
  begin
    // Standard CNROM boards AND CPU data with the byte driven by PRG ROM.
    if FBusConflicts then
      Value := Value and FPrgRom[Address and FPrgReadMask];
    SelectChrBank(Value);
    Exit(True);
  end;

  Result := (FPrgRamSize <> 0) and (Address >= $6000);
  if Result then
    FPrgRam[(Address and $1FFF) mod FPrgRamSize] := Value;
end;

function TMapperCnrom.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[FChrOffset + Address];
end;

function TMapperCnrom.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[FChrOffset + Address] := Value;
end;

function TMapperCnrom.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

procedure TMapperCnrom.Reset;
begin
  SelectChrBank(0);
end;

constructor TMapperAerobicsStudio.Create(const Prg, Chr: NES.Types.TByteArray; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, False, MirrorMode);
  SetRegion(TNesRegion.NTSC);
end;

procedure TMapperAerobicsStudio.LoadRecordings(const Storage: IStorage; const RomName: string);
begin
  LoadSpeechRecordings(Storage, RomName, 'm50805', 8, FRecordings);
  LoadSpeechRecordings(Storage, RomName, 'ftaerobi', 8, FRecordings);
end;

procedure TMapperAerobicsStudio.Reset;
begin
  inherited;
  FSpeech := Default(TPlayback);
  FSpeechStart := Default(TSpeechStart);
end;

procedure TMapperAerobicsStudio.SetRegion(Region: TNesRegion);
begin
  FCpuHz := CpuFrequency(Region);
  // M50805 microcomputer mode requires at least 18 us low on SYNC.
  // The datasheet lists 40-60 ms to begin speech. Use the midpoint for playback.
  FSyncPulseCycles := (FCpuHz * 18 + 999999) div 1000000;
  FSpeechDelayCycles := (FCpuHz + 19) div 20;
end;

function TMapperAerobicsStudio.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address and $E000) <> $6000 then
    Exit(inherited CpuWrite(Address, Value));
  var SyncHigh := (Value and $40) <> 0;
  FSpeechStart.InputTrack := Value and 7;
  if SyncHigh then
    FSpeechStart.CyclesToLatch := 0
  // In microcomputer mode BUSY blocks another start until the phrase ends.
  else if FSpeech.SyncHigh and not FSpeech.Active and (FSpeechStart.CyclesToOutput = 0) then
    FSpeechStart.CyclesToLatch := FSyncPulseCycles;
  FSpeech.SyncHigh := SyncHigh;
  Result := True;
end;

procedure TMapperAerobicsStudio.StartSpeech;
begin
  FSpeech.MessageIndex := FSpeechStart.OutputTrack;
  FSpeech.Position := 0;
  FSpeech.Phase := 0;
  FSpeech.Sample := 0;
  FSpeech.Active := Length(FRecordings[FSpeech.MessageIndex].Samples) <> 0;
  if FSpeech.Active then
  begin
    FSpeech.Sample := FRecordings[FSpeech.MessageIndex].Samples[0];
    FSpeech.Position := 1;
  end;
end;

procedure TMapperAerobicsStudio.ClockCpu;
begin
  if FSpeechStart.CyclesToLatch > 0 then
  begin
    Dec(FSpeechStart.CyclesToLatch);
    if FSpeechStart.CyclesToLatch = 0 then
    begin
      FSpeechStart.OutputTrack := FSpeechStart.InputTrack;
      // The first tick of the output countdown is this same CPU cycle.
      FSpeechStart.CyclesToOutput := FSpeechDelayCycles - FSyncPulseCycles + 1;
    end;
  end;
  if FSpeechStart.CyclesToOutput > 0 then
  begin
    Dec(FSpeechStart.CyclesToOutput);
    if FSpeechStart.CyclesToOutput = 0 then
    begin
      StartSpeech;
      Exit;
    end;
  end;
  if not FSpeech.Active then
    Exit;
  var MessageIndex := FSpeech.MessageIndex;
  Inc(FSpeech.Phase, FRecordings[MessageIndex].Rate);
  if FSpeech.Phase < FCpuHz then
    Exit;
  Dec(FSpeech.Phase, FCpuHz);
  if FSpeech.Position = Length(FRecordings[MessageIndex].Samples) then
  begin
    FSpeech.Active := False;
    FSpeech.Sample := 0;
    Exit;
  end;
  FSpeech.Sample := FRecordings[MessageIndex].Samples[FSpeech.Position];
  Inc(FSpeech.Position);
end;

function TMapperAerobicsStudio.ExpansionAudio: Double;
begin
  Result := FSpeech.Sample * (1.0 / 131072.0);
end;

procedure TMapperAerobicsStudio.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 40 then
  begin
    State.Field(FSpeech, SizeOf(FSpeech));
    if State.Loading then
    begin
      if (FSpeech.MessageIndex > 7) or (Cardinal(FSpeech.Phase) >= Cardinal(FCpuHz)) or
        (Cardinal(FSpeech.Position) > 960000) then
        raise EReadError.Create('Invalid Aerobics Studio speech state');
      var Count := Length(FRecordings[FSpeech.MessageIndex].Samples);
      if (Count = 0) or (FSpeech.Position > Count) then
      begin
        FSpeech.Active := False;
        FSpeech.Sample := 0;
      end;
    end;
  end
  else if State.Loading then
    FSpeech := Default(TPlayback);

  if State.Version >= 41 then
  begin
    State.Field(FSpeechStart, SizeOf(FSpeechStart));
    if State.Loading and ((FSpeechStart.InputTrack > 7) or (FSpeechStart.OutputTrack > 7) or
      (Cardinal(FSpeechStart.CyclesToLatch) > Cardinal(FSyncPulseCycles)) or
      (Cardinal(FSpeechStart.CyclesToOutput) > Cardinal(FSpeechDelayCycles)) or
      (FSpeech.SyncHigh and (FSpeechStart.CyclesToLatch <> 0))) then
      raise EReadError.Create('Invalid Aerobics Studio speech timing state');
  end
  else if State.Loading then
    FSpeechStart := Default(TSpeechStart);
end;

end.

