unit SNES.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Hash, Core.Snapshots, SNES.SDD1,
  SNES.NecDSP, SNES.CX4, SNES.SA1, SNES.GSU, SNES.SPC7110, SNES.ST018;

type
  TSnesMapping = (LoROM, HiROM, ExLoROM, ExHiROM);

  TSnesHeader = record
    Mapping: TSnesMapping;
    Offset, CopierSize, Score: Integer;
    PAL: Boolean;
  end;

  TSnesCartridge = class
  private
    FData, FSRAM: TBytes;
    FHeader: TSnesHeader;
    FDirty: Boolean;
    FActionReplay: Boolean;
    FReplayControl: Byte;
    FObc1: Boolean;
    FSDD1: TSnesSDD1;
    FDSP: TSnesNecDSP;
    FCX4: TSnesCX4;
    FCX4Target: UInt64;
    FSA1: TSnesSA1;
    FGSU: TSnesGSU;
    FSPC7110: TSnesSPC7110;
    FST018: TSnesST018;
    FST: Boolean;
    FDSPFrequency: Integer;
    FDSPTarget: Int64;
    function ReadRawROM(Address: Cardinal): Byte;
    function GSUAddress(Address: Cardinal; out Offset: Cardinal): Integer;
    function CX4Map(Address: Cardinal): TCx4Memory;
    function CX4Read(Address: Cardinal): Byte;
    procedure CX4Write(Address: Cardinal; Value: Byte);
    function GetCoprocessorIRQ: Boolean;
    function DSPAddress(Address: Cardinal; out Status: Boolean): Boolean;
    function GetBatteryDirty: Boolean;
    function ReadSDD1ROM(Address: Cardinal): Byte;
    function Mirror(Address: Integer): Integer;
    function SRAMAddress(Address: Cardinal): Integer;
    function Obc1Address(Address: Cardinal): Integer;
  public
    constructor Create(const Data: TBytes; const Firmware: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure SyncDSP(MasterClock: Int64; MasterRate: Integer; Run: Boolean = False);
    procedure HostAccess(Address: Cardinal; Fast: Boolean);
    function Read(Address: Cardinal; OpenBus: Byte): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    procedure MarkBatteryDirty;
    procedure SerializeState(State: TStateArchive);
    property BatteryDirty: Boolean read GetBatteryDirty;
    property Data: TBytes read FData;
    property Header: TSnesHeader read FHeader;
    property CoprocessorIRQ: Boolean read GetCoprocessorIRQ;
    property ActionReplay: Boolean read FActionReplay;
  end;

function DetectSnesHeader(const Data: TBytes; out Header: TSnesHeader): Boolean;

function SnesDSPFirmwareName(const Data: TBytes): string;

function SnesEmbeddedFirmwareSize(const Data: TBytes): Integer;

function SnesResourceFirmware(const Name: string): TBytes;

const
  DSP3Title: array[0..9] of Byte = ($53, $44, $B6, $DE, $DD, $C0, $DE, $D1, $47, $58);

implementation

{$R 'SNES.Firmware.res' 'SNES.Firmware.rc'}

uses
  Core.RomHashes, Core.RomFormat;

function SnesResourceFirmware(const Name: string): TBytes;
begin
  var ExpectedSize: Integer;
  if (Name = 'dsp1') or (Name = 'dsp1b') or (Name = 'dsp2') or (Name = 'dsp3') or (Name = 'dsp4') then
    ExpectedSize := $2000
  else if (Name = 'st010') or (Name = 'st011') then
    ExpectedSize := $D000
  else if Name = 'st018' then
    ExpectedSize := $28000
  else
    raise EArgumentException.Create('Unknown SNES firmware: ' + Name);

  var Resource := TResourceStream.Create(HInstance, 'SNES_' + UpperCase(Name), PChar(10));
  try
    if Resource.Size <> ExpectedSize then
      raise EReadError.Create('Invalid SNES firmware resource size: ' + Name);

    SetLength(Result, ExpectedSize);
    Resource.ReadBuffer(Result[0], ExpectedSize);
  finally
    Resource.Free;
  end;
end;

function IsActionReplayBIOS(const Data: TBytes; CopierSize: Integer): Boolean;
begin
  Result := False;
  var Size := Length(Data) - CopierSize;
  if (Size <> $8000) and (Size <> $20000) then
    Exit;
  var Hasher := THashSHA2.Create;
  Hasher.Update(Data[CopierSize], Size);
  var Hash := Hasher.HashAsString;

  // Known standalone Datel BIOS dumps (PAR, Mk2 v1.1, Mk3), not game headers.
  Result :=
    SameText(Hash, ROM_SNES_PRO_ACTION_REPLAY_BIOS_SHA256) or
    SameText(Hash, ROM_SNES_PRO_ACTION_REPLAY_MK2_V11_BIOS_SHA256) or
    SameText(Hash, ROM_SNES_PRO_ACTION_REPLAY_MK3_BIOS_SHA256);
end;

function EmptySnesMetadata(const Data: TBytes; Offset: Integer): Boolean;
begin
  // Some early homebrew leaves the metadata erased but supplies valid vectors.
  for var J := 0 to $1F do
    if Data[Offset + J] <> $FF then
      Exit(False);
  Result := True;
end;

function UnusableSnesMetadata(const Data: TBytes; Offset: Integer): Boolean;
begin
  if EmptySnesMetadata(Data, Offset) then
    Exit(True);
  // Early prototypes and PD programs can put executable code/graphics in
  // this area. Do not interpret those bytes as a coprocessor or RAM size.
  // A valid checksum pair or plausible mapping/ROM size keeps real headers.
  var Mode := Data[Offset + $15] and $EF;
  var Checksum := Data[Offset + $1E] or (Word(Data[Offset + $1F]) shl 8);
  var Complement := Data[Offset + $1C] or (Word(Data[Offset + $1D]) shl 8);
  Result := not (Mode in [$20, $21, $22, $23, $25]) and
    (Data[Offset + $17] >= $10) and
    not ((Checksum + Complement = $FFFF) and (Checksum <> 0) and (Complement <> 0));
end;

function SnesDSPFirmwareName(const Data: TBytes): string;
begin
  Result := '';
  var Header: TSnesHeader;
  if not DetectSnesHeader(Data, Header) then
    Exit;
  if UnusableSnesMetadata(Data, Header.Offset) then
    Exit;
  if IsActionReplayBIOS(Data, Header.CopierSize) then
    Exit;

  var Title := TEncoding.ASCII.GetString(Data, Header.Offset, 21).Trim;
  var Kind := Data[Header.Offset + $16];
  if ((Kind and $F) >= 3) and ((Kind shr 4) = $F) and (Data[Header.Offset - 1] = 2) then
    Exit('st018');

  if ((Kind and $F) >= 3) and ((Kind shr 4) = $F) and (Data[Header.Offset - 1] = 1) then
  begin
    if Title = '2DAN MORITA SHOUGI' then
      Result := 'st011'
    else
      Result := 'st010';
    Exit;
  end;

  if not (Kind in [3, 5]) then
    Exit;

  if Title = 'DUNGEON MASTER' then
    Result := 'dsp2'
  else if Title = 'PILOTWINGS' then
    Result := 'dsp1'
  else if (Title = 'PLANETS CHAMP TG3000') or (Title = 'TOP GEAR 3000') then
    Result := 'dsp4'
  else if CompareMem(@Data[Header.Offset], @DSP3Title[0], Length(DSP3Title)) then
    Result := 'dsp3'
  else
    Result := 'dsp1b';
end;

function SnesEmbeddedFirmwareSize(const Data: TBytes): Integer;
begin
  Result := 0;
  var Name := SnesDSPFirmwareName(Data);
  if Name = '' then
    Exit;

  var Header: TSnesHeader;
  DetectSnesHeader(Data, Header);
  var Size := Length(Data) - Header.CopierSize;
  if Name = 'st018' then
  begin
    if (Size and $3FFFF) = $28000 then
      Result := $28000;
  end
  else if Name.StartsWith('st0') then
  begin
    if (Size and $FFFF) = $D000 then
      Result := $D000;
  end
  else if (Size and $7FFF) = $2000 then
    Result := $2000;
end;

function DetectSnesHeader(const Data: TBytes; out Header: TSnesHeader): Boolean;
begin
  Header := Default(TSnesHeader);
  Header.Score := -1;
  for var Base in SNES_ROM_HEADER_BASES do
  begin
    // A 512-byte copier prefix leaves this residue even with DSP firmware
    // appended. Full KiB images must not select a header inside game code.
    if ((Base and ROM_COPIER_HEADER_SIZE) <> 0) and
      ((Length(Data) and $3FF) <> ROM_COPIER_HEADER_SIZE) then
      Continue;
    if Length(Data) < Base + $8000 then
      Continue;

    var H := Base + $7FC0;
    var Reset := Data[H + $3C] or (Word(Data[H + $3D]) shl 8);
    if Reset < $8000 then
      Continue;

    var Mode := Data[H + $15] and $EF;
    var Score := 0;
    if ((Mode in [$20, $22]) and ((Base and $8000) = 0)) or ((Mode in [$21, $25]) and ((Base and $8000) <> 0)) then
      Inc(Score, 2);
    if Data[H + $16] < 8 then
      Inc(Score);
    if Data[H + $17] < $10 then
      Inc(Score);
    if Data[H + $18] < 8 then
      Inc(Score);
    var Checksum := Data[H + $1E] or (Word(Data[H + $1F]) shl 8);
    var Complement := Data[H + $1C] or (Word(Data[H + $1D]) shl 8);
    if (Checksum + Complement = $FFFF) and (Checksum <> 0) and (Complement <> 0) then
      Inc(Score, 8);
    var Op := Data[Base + (Reset and $7FFF)];
    case Op of
      $18, $78, $4C, $5C, $DC, $20, $22, $9C:
        Inc(Score, 8);
      $C2, $E2, $A9, $A2, $A0, $EA:
        Inc(Score, 4);
      $00, $FF, $CC:
        Dec(Score, 8);
    end;

    // Reject accidental headers in arbitrary binary files.
    if Score < 8 then
      Continue;
    if Score < Header.Score then
      Continue;

    Header.Score := Score;
    Header.Offset := H;
    Header.CopierSize := Base and ROM_COPIER_HEADER_SIZE;
    if (Base and $8000) = 0 then
      if (Base and $400000) = 0 then
        Header.Mapping := LoROM
      else
        Header.Mapping := ExLoROM
    else if (Base and $400000) = 0 then
      Header.Mapping := HiROM
    else
      Header.Mapping := ExHiROM;
    if Mode = $25 then
      Header.Mapping := ExHiROM;
    Header.PAL := Data[H + $19] in [2..12];
  end;
  Result := Header.Score >= 8;
end;

constructor TSnesCartridge.Create(const Data: TBytes; const Firmware: TBytes);
begin
  inherited Create;
  if not DetectSnesHeader(Data, FHeader) then
    raise EReadError.Create('Invalid SNES ROM header');

  FData := Copy(Data, FHeader.CopierSize, Length(Data) - FHeader.CopierSize);
  Dec(FHeader.Offset, FHeader.CopierSize);
  FActionReplay := IsActionReplayBIOS(FData, 0);
  if FActionReplay then
    FHeader.Mapping := LoROM;
  var Kind := FData[FHeader.Offset + $16];
  var EmptyMetadata := UnusableSnesMetadata(FData, FHeader.Offset);
  if EmptyMetadata or FActionReplay then
    Kind := 0;
  var FirmwareName := SnesDSPFirmwareName(Data);
  FST := (FirmwareName = 'st010') or (FirmwareName = 'st011');
  FObc1 := Kind = $25;
  var HasCX4 := ((Kind and $F) >= 3) and ((Kind shr 4) = $F) and (FData[FHeader.Offset - 1] = $10);
  var HasSA1 := ((Kind and $F) >= 3) and ((Kind shr 4) = 3);
  var HasGSU := Kind in [$13, $14, $15, $1A];
  var HasSPC := ((Kind and $F) >= 3) and ((Kind shr 4) = $F) and (FData[FHeader.Offset - 1] = 0);
  if HasCX4 then
    FHeader.Mapping := LoROM;
  // Types with low nibble 0-2 have no coprocessor, even with a nonzero family nibble.
  if not FST and not HasCX4 and not HasSA1 and not HasGSU and not HasSPC and (FirmwareName <> 'st018') and
    ((Kind and $F) >= 3) and not (Kind in [3, 5, $25, $43, $45]) then
    raise ENotSupportedException.CreateFmt('SNES cartridge coprocessor $%.2x is not ported yet', [Kind]);

  var Size := FData[FHeader.Offset + $18] and $F;
  if EmptyMetadata then
    Size := 0;
  if FActionReplay then
    Size := 5; // Four 8 KiB SRAM windows at 00/02/04/06:6000-7FFF.
  if Size > 8 then
    raise EReadError.Create('Invalid SNES SRAM size');

  if (Size > 0) and not FST then
    SetLength(FSRAM, 1024 shl Size);
  if FObc1 and (Length(FSRAM) < $2000) then
    raise EReadError.Create('OBC1 requires at least 8 KiB SRAM');

  if Kind in [$43, $45] then
    FSDD1 := TSnesSDD1.Create(ReadSDD1ROM);
  if HasCX4 then
    FCX4 := TSnesCX4.Create(CX4Read, CX4Write, CX4Map);
  if HasSA1 then
    FSA1 := TSnesSA1.Create(ReadRawROM, Length(FSRAM));

  if HasGSU then
  begin
    var RamSize := $10000;
    if (FData[FHeader.Offset + $1A] = $33) and (FData[FHeader.Offset - 3] in [1..7]) then
      RamSize := 1024 shl FData[FHeader.Offset - 3];
    FGSU := TSnesGSU.Create(ReadRawROM, RamSize);
  end;
  if HasSPC then
  begin
    var DataSize := Length(FData) - $100000;
    if Length(FData) >= $600000 then
      Dec(DataSize, $100000);
    if DataSize < 0 then
      DataSize := 0;
    FSPC7110 := TSnesSPC7110.Create(ReadRawROM, DataSize, (Kind and $F) = 9);
  end;

  if FirmwareName <> '' then
  begin
    var DSPFirmware := Firmware;
    var EmbeddedSize := SnesEmbeddedFirmwareSize(Data);
    if EmbeddedSize > 0 then
    begin
      DSPFirmware := Copy(FData, Length(FData) - EmbeddedSize, EmbeddedSize);
      SetLength(FData, Length(FData) - EmbeddedSize);
    end;
    if Length(DSPFirmware) = 0 then
      DSPFirmware := SnesResourceFirmware(FirmwareName);
    if FirmwareName = 'st018' then
    begin
      FST018 := TSnesST018.Create(DSPFirmware);
      Exit;
    end;

    FDSPFrequency := 7600000;
    if FirmwareName = 'st010' then
      FDSPFrequency := 11000000
    else if FirmwareName = 'st011' then
      FDSPFrequency := 22000000;
    FDSP := TSnesNecDSP.Create(DSPFirmware, FST);
  end;
end;

destructor TSnesCartridge.Destroy;
begin
  FST018.Free;
  FSPC7110.Free;
  FGSU.Free;
  FSA1.Free;
  FCX4.Free;
  FDSP.Free;
  FSDD1.Free;
  inherited;
end;

procedure TSnesCartridge.HostAccess(Address: Cardinal; Fast: Boolean);
begin
  if FSA1 <> nil then
    FSA1.HostAccess(Address, Fast);
end;

procedure TSnesCartridge.Reset;
begin
  FReplayControl := 0;
  FCX4Target := 0;
  if FCX4 <> nil then
    FCX4.Reset;
  if FSA1 <> nil then
    FSA1.Reset;
  if FGSU <> nil then
    FGSU.Reset;
  if FSPC7110 <> nil then
    FSPC7110.Reset;
  if FST018 <> nil then
    FST018.Reset;
  FDSPTarget := 0;
  if FDSP <> nil then
    FDSP.Reset;
  if FSDD1 <> nil then
    FSDD1.Reset;
end;

procedure TSnesCartridge.SyncDSP(MasterClock: Int64; MasterRate: Integer; Run: Boolean);
begin
  if FSA1 <> nil then
    FSA1.RunUntil(UInt64(MasterClock));
  if FGSU <> nil then
    FGSU.RunUntil(UInt64(MasterClock));
  if FST018 <> nil then
    FST018.RunUntil(UInt64(MasterClock));
  if FCX4 <> nil then
  begin
    FCX4Target := UInt64((MasterClock div MasterRate) * 20000000 + (MasterClock mod MasterRate) * 20000000 div MasterRate);
    // CX4 can assert IRQ while the CPU is running, so synchronize at each instruction/access.
    FCX4.RunUntil(FCX4Target);
  end;
  if FDSP = nil then
    Exit;

  // Split the quotient to avoid overflowing Int64 in long-running sessions.
  FDSPTarget := (MasterClock div MasterRate) * FDSPFrequency +
    (MasterClock mod MasterRate) * FDSPFrequency div MasterRate;
  if Run then
    FDSP.RunUntil(FDSPTarget);
end;

function TSnesCartridge.GetCoprocessorIRQ: Boolean;
begin
  Result := ((FCX4 <> nil) and FCX4.IRQ) or ((FSA1 <> nil) and FSA1.IRQ) or ((FGSU <> nil) and FGSU.State.SFR.IRQ);
end;

function TSnesCartridge.ReadRawROM(Address: Cardinal): Byte;
begin
  if Address = $FFFFFFFF then
    Exit(0);

  Result := FData[Mirror(Integer(Address))];
end;

function TSnesCartridge.GSUAddress(Address: Cardinal; out Offset: Cardinal): Integer;
begin
  var Bank := Address shr 16;
  Offset := Address and $FFFF;
  Result := 0;

  if ((Bank and $7F) < $40) then
  begin
    if (Offset >= $3000) and (Offset <= $3FFF) then
      Exit(1);
    if (Offset >= $6000) and (Offset <= $7FFF) and ((Bank and $7F) < $3F) then
    begin
      Offset := Offset and $1FFF;
      Exit(2);
    end;
    if Offset >= $8000 then
      Exit(3);
  end;

  if Bank in [$70, $71, $F0, $F1] then
  begin
    Offset := Address and $1FFFF;
    Exit(2);
  end;
  if (Bank in [$40..$5F, $C0..$DF]) then
    Exit(3);
end;

function TSnesCartridge.CX4Map(Address: Cardinal): TCx4Memory;
begin
  var Bank := (Address shr 16) and $FF;
  var Offset := Address and $FFFF;
  Result := Unmapped;

  if Offset >= $8000 then
    Exit(ROM);
  if ((Bank and $7F) < $40) and (Offset >= $6000) then
    Exit(Registers);
  if (Length(FSRAM) > 0) and ((Bank in [$70..$7D]) or (Bank >= $F0)) then
    Exit(SRAM);
end;

function TSnesCartridge.CX4Read(Address: Cardinal): Byte;
begin
  case CX4Map(Address) of
    ROM:
      Result := FData[Mirror(((Address shr 16 and $7F) shl 15) or (Address and $7FFF))];
    SRAM:
      Result := FSRAM[(((Address shr 16 and $F) shl 15) or (Address and $7FFF)) and (Length(FSRAM) - 1)];
    Registers:
      Result := FCX4.Read(Address);
  else
    Result := 0;
  end;
end;

procedure TSnesCartridge.CX4Write(Address: Cardinal; Value: Byte);
begin
  case CX4Map(Address) of
    Registers:
      FCX4.Write(Address, Value);
    SRAM:
      begin
        var Index := (((Address shr 16 and $F) shl 15) or (Address and $7FFF)) and (Length(FSRAM) - 1);
        if FSRAM[Index] <> Value then
        begin
          FSRAM[Index] := Value;
          FDirty := True;
        end;
      end;
  end;
end;

function TSnesCartridge.DSPAddress(Address: Cardinal; out Status: Boolean): Boolean;
begin
  Result := False;
  Status := False;
  if FDSP = nil then
    Exit;

  var Bank := Address shr 16 and $7F;
  var Offset := Address and $FFFF;
  if FST then
  begin
    Result := ((Bank = $60) or ((Bank >= $68) and (Bank <= $6F))) and (Offset <= $FFF);
    Status := (Offset and 1) <> 0;
    Exit;
  end;

  if FHeader.Mapping in [LoROM, ExLoROM] then
  begin
    Result := ((Bank >= $30) and (Bank <= $3F) and (Offset >= $8000)) or
      ((Bank >= $60) and (Bank <= $6F) and (Offset < $8000));
    Status := (Offset and $4000) <> 0;
  end
  else
  begin
    Result := (Bank < $20) and (Offset >= $6000) and (Offset <= $7FFF);
    Status := (Offset and $1000) <> 0;
  end;
end;

function TSnesCartridge.ReadSDD1ROM(Address: Cardinal): Byte;
begin
  Result := FData[Mirror(FSDD1.MapROM(Address))];
end;

function TSnesCartridge.Obc1Address(Address: Cardinal): Integer;
begin
  Result := -1;
  if not FObc1 or ((Address shr 16 and $7F) >= $40) or ((Address and $FFFF) < $6000) or ((Address and $FFFF) > $7FFF) then
    Exit;

  var A := Integer(Address and $1FFF);
  var Base := $1800 or ((not FSRAM[$1FF5] and 1) shl 10);
  var Obj := FSRAM[$1FF6] and $7F;
  case A of
    $1FF0..$1FF3:
      Result := Base or (Obj shl 2) or (A and 3);
    $1FF4:
      Result := (Base or (Obj shr 2)) + $200;
  else
    Result := A;
  end;
end;

function TSnesCartridge.Mirror(Address: Integer): Integer;
begin
  // Hardware folds non-power-of-two ROMs by the highest address line.
  var Size := Length(FData);
  var Base := 0;
  var Mask := $800000;
  while Address >= Size do
  begin
    while (Address and Mask) = 0 do
      Mask := Mask shr 1;
    Dec(Address, Mask);
    if Size > Mask then
    begin
      Dec(Size, Mask);
      Inc(Base, Mask);
    end;
    Mask := Mask shr 1;
  end;
  Result := Base + Address;
end;

function TSnesCartridge.SRAMAddress(Address: Cardinal): Integer;
begin
  Result := -1;
  if Length(FSRAM) = 0 then
    Exit;

  var Bank := Address shr 16;
  var Offset := Address and $FFFF;
  if FActionReplay then
  begin
    if ((Bank and $F9) = 0) and (Offset >= $6000) and (Offset < $8000) then
      Result := ((Bank shr 1) shl 13) or (Offset and $1FFF);
    Exit;
  end;

  if FSDD1 <> nil then
  begin
    if ((Bank and $7F) < $40) and (Offset >= $6000) and (Offset < $8000) then
      Result := (Offset and $1FFF) and (Length(FSRAM) - 1)
    else if Bank in [$70..$73] then
      Result := Offset and (Length(FSRAM) - 1);
    Exit;
  end;

  if FHeader.Mapping in [LoROM, ExLoROM] then
  begin
    if ((Bank and $7F) >= $70) and ((Bank and $7F) <= $7D) and (Offset < $8000) then
      Result := (((Bank and $F) shl 15) or Offset) and (Length(FSRAM) - 1);
  end
  else if ((Bank and $7F) in [$20..$3F]) and (Offset >= $6000) and (Offset < $8000) then
    Result := (((Bank and $1F) shl 13) or (Offset and $1FFF)) and (Length(FSRAM) - 1);
end;

function TSnesCartridge.Read(Address: Cardinal; OpenBus: Byte): Byte;
begin
  // No game is attached to a standalone BIOS. Control A temporarily exposes it.
  // The 80-BF BIOS mirror remains visible during the 00-3F game-ROM peek.
  if FActionReplay and ((FReplayControl and $10) <> 0) and ((Address shr 16) < $40) and ((Address and $FFFF) >= $8000) then
    Exit($FF);
  if FSA1 <> nil then
    Exit(FSA1.Read(Address, OpenBus));

  if FGSU <> nil then
  begin
    var Offset: Cardinal;
    case GSUAddress(Address, Offset) of
      1:
        Exit(FGSU.Read(Address));
      2:
        Exit(FGSU.CPUReadRAM(Offset, OpenBus));
      3:
        Exit(FGSU.CPUReadROM(Address));
    else
      Exit(OpenBus);
    end;
  end;

  if (FST018 <> nil) and ((Address shr 16 and $7F) < $40) and ((Address and $FFFF) >= $3000) and ((Address and $FFFF) <= $3FFF) then
    Exit(FST018.Read(Address, OpenBus));

  if FSPC7110 <> nil then
  begin
    var Bank := Address shr 16;
    var Offset := Address and $FFFF;
    if (Bank in [$50, $58]) or (((Bank and $7F) < $40) and (Offset >= $4800) and (Offset <= $4842)) then
      Exit(FSPC7110.Read(Address, OpenBus));
    if ((Bank and $7F) < $40) and (Offset >= $6000) and (Offset < $8000) and (Length(FSRAM) > 0) then
      Exit(FSRAM[Offset and $1FFF and (Length(FSRAM) - 1)]);
    if (Bank >= $C0) or (((Bank and $7F) < $40) and (Offset >= $8000)) or ((Length(FData) >= $600000) and (Bank in [$40..$4F])) then
      Exit(ReadRawROM(FSPC7110.ROMAddress(Address)));
    Exit(OpenBus);
  end;

  if FCX4 <> nil then
  begin
    FCX4.RunUntil(FCX4Target);
    if CX4Map(Address) = Unmapped then
      Exit(OpenBus);
    Exit(CX4Read(Address));
  end;

  var Status: Boolean;
  if DSPAddress(Address, Status) then
  begin
    FDSP.RunUntil(FDSPTarget);
    if FST and ((Address and $F0000) >= $80000) then
      Exit(FDSP.ReadRAMByte(Address));
    Exit(FDSP.Read(Status));
  end;

  var Obc := Obc1Address(Address);
  if Obc >= 0 then
    Exit(FSRAM[Obc]);

  var Save := SRAMAddress(Address);
  if Save >= 0 then
    Exit(FSRAM[Save]);

  var Bank := Address shr 16;
  var Offset := Address and $FFFF;
  var Index: Integer;
  if FSDD1 <> nil then
  begin
    if ((Bank and $7F) < $40) and (Offset >= $4800) and (Offset <= $4807) then
      Exit(FSDD1.ReadRegister(Word(Offset), OpenBus));
    if (Bank >= $C0) or (((Bank and $7F) < $40) and (Offset >= $8000)) then
      Exit(FSDD1.Read(Address));
    Exit(OpenBus);
  end;

  if (Offset < $8000) and ((Bank and $7F) < $40) then
    Exit(OpenBus);

  if FHeader.Mapping in [LoROM, ExLoROM] then
  begin
    Index := ((Bank and $7F) shl 15) or (Offset and $7FFF);
    if (FHeader.Mapping = ExLoROM) and (Bank < $80) then
      Inc(Index, $400000);
  end
  else
  begin
    Index := ((Bank and $3F) shl 16) or Offset;
    if (FHeader.Mapping = ExHiROM) and (Bank < $C0) then
      Inc(Index, $400000);
  end;
  Result := FData[Mirror(Index)];
end;

procedure TSnesCartridge.Write(Address: Cardinal; Value: Byte);
begin
  if FActionReplay and (Address = $10001C) then
  begin
    FReplayControl := Value;
    Exit;
  end;
  if FSA1 <> nil then
  begin
    FSA1.Write(Address, Value);
    Exit;
  end;

  if FGSU <> nil then
  begin
    var Offset: Cardinal;
    case GSUAddress(Address, Offset) of
      1:
        FGSU.Write(Address, Value);
      2:
        FGSU.CPUWriteRAM(Offset, Value);
    end;
    Exit;
  end;

  if (FST018 <> nil) and ((Address shr 16 and $7F) < $40) and ((Address and $FFFF) >= $3000) and ((Address and $FFFF) <= $3FFF) then
  begin
    FST018.Write(Address, Value);
    Exit;
  end;

  if FSPC7110 <> nil then
  begin
    var Bank := Address shr 16;
    var Offset := Address and $FFFF;
    if (Bank in [$50, $58]) or (((Bank and $7F) < $40) and (Offset >= $4800) and (Offset <= $4842)) then
      FSPC7110.Write(Address, Value)
    else if ((Bank and $7F) < $40) and (Offset >= $6000) and (Offset < $8000) and (Length(FSRAM) > 0) then
    begin
      var Index := Offset and $1FFF and (Length(FSRAM) - 1);
      if FSRAM[Index] <> Value then
      begin
        FSRAM[Index] := Value;
        FDirty := True;
      end;
    end;
    Exit;
  end;

  if FCX4 <> nil then
  begin
    FCX4.RunUntil(FCX4Target);
    CX4Write(Address, Value);
    Exit;
  end;

  var Status: Boolean;
  if DSPAddress(Address, Status) then
  begin
    FDSP.RunUntil(FDSPTarget);
    if FST and ((Address and $F0000) >= $80000) then
      FDSP.WriteRAMByte(Address, Value)
    else
      FDSP.Write(Status, Value);
    Exit;
  end;

  if (FSDD1 <> nil) and ((Address shr 16 and $7F) < $40) then
    FSDD1.Write(Word(Address), Value);
  var Index := Obc1Address(Address);
  if (Index >= 0) and ((Address and $1FFF) = $1FF4) then
  begin
    var Shift := (FSRAM[$1FF6] and 3) shl 1;
    Value := (FSRAM[Index] and not (3 shl Shift)) or ((Value and 3) shl Shift);
  end;
  if Index < 0 then
    Index := SRAMAddress(Address);
  if (Index >= 0) and (FSRAM[Index] <> Value) then
  begin
    FSRAM[Index] := Value;
    FDirty := True;
  end;
end;

procedure TSnesCartridge.LoadBattery(const Data: TBytes);
begin
  if FSA1 <> nil then
  begin
    FSA1.LoadBattery(Data);
    Exit;
  end;

  if FGSU <> nil then
  begin
    FGSU.LoadBattery(Data);
    Exit;
  end;

  if (FSPC7110 <> nil) and (Length(FSPC7110.RTCBattery) > 0) then
  begin
    if Length(Data) <> Length(FSRAM) + 24 then
      raise EReadError.Create('SPC7110 battery size mismatch');

    FSRAM := Copy(Data, 0, Length(FSRAM));
    FSPC7110.LoadRTCBattery(Copy(Data, Length(FSRAM), 24));
    FDirty := False;
    Exit;
  end;

  if FST then
  begin
    FDSP.LoadBattery(Data);
    FDirty := False;
    Exit;
  end;

  if Length(Data) <> Length(FSRAM) then
    raise EReadError.Create('SNES SRAM size mismatch');

  FSRAM := Copy(Data);
  FDirty := False;
end;

function TSnesCartridge.BatteryData: TBytes;
begin
  if FSA1 <> nil then
    Exit(FSA1.Battery);
  if FGSU <> nil then
    Exit(Copy(FGSU.RAM));

  if FST then
    Result := FDSP.BatteryData
  else
    Result := Copy(FSRAM);
  if FSPC7110 <> nil then
    Result := Result + FSPC7110.RTCBattery;
end;

function TSnesCartridge.GetBatteryDirty: Boolean;
begin
  Result := FDirty;
  if FST and (FDSP <> nil) then
    Result := Result or FDSP.BatteryDirty;
  if FSA1 <> nil then
    Result := Result or FSA1.BatteryDirty;
  if FGSU <> nil then
    Result := Result or FGSU.BatteryDirty;
  if FSPC7110 <> nil then
    Result := Result or (Length(FSPC7110.RTCBattery) > 0);
end;

procedure TSnesCartridge.MarkBatteryDirty;
begin
  FDirty := True;
end;

procedure TSnesCartridge.SerializeState(State: TStateArchive);
begin
  if FActionReplay then
    State.Field(FReplayControl, SizeOf(FReplayControl));
  if Length(FSRAM) > 0 then
    State.Field(FSRAM[0], Length(FSRAM));
  if FSDD1 <> nil then
    FSDD1.SerializeState(State);
  if FDSP <> nil then
    FDSP.SerializeState(State);
  if FCX4 <> nil then
    FCX4.SerializeState(State);
  if FSA1 <> nil then
    FSA1.SerializeState(State);
  if FGSU <> nil then
    FGSU.SerializeState(State);
  if FSPC7110 <> nil then
    FSPC7110.SerializeState(State);
  if FST018 <> nil then
    FST018.SerializeState(State);
end;

end.

