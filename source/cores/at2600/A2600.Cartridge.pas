unit A2600.Cartridge;

interface

uses
  System.Classes, System.SysUtils, Core.Snapshots, A2600.DPC, A2600.Supercharger;

type
  TA2600Mapper = (m2K, m4K, mF8, mF6, mF4, mE0, m3F, mFA, mE7, mFE, mUA, mCV, m0840, mMB, mMC32, mDPC, mAR, mCM, mMC16);

  TA2600CartridgeState = record
    RAM: array[0..127] of Byte;
    FARAM: array[0..255] of Byte;
    Bank: Integer;
    Segments: array[0..2] of Integer;
  end;

  TA2600Cartridge = class
  private
    FData: TBytes;
    FMapper: TA2600Mapper;
    FSuperchip: Boolean;
    FState: TA2600CartridgeState;
    FExtraRAM: array[0..2047] of Byte;
    FRAMBank: Integer;
    FSWCHA: Byte;
    FFEPending: Boolean;
    FDPC: TA2600DPC;
    FSupercharger: TA2600Supercharger;
  public
    constructor Create(const Data: TBytes; const Mapper: string = '');
    destructor Destroy; override;
    procedure Clock(CPUFrequency: Double);
    procedure Reset;
    procedure Hotspot(Address: Word; Value: Byte; Writing: Boolean);
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure ValidateState;
    procedure Observe(Address: Word; Value: Byte);
    procedure SerializeExtra(State: TStateArchive);
    property Mapper: TA2600Mapper read FMapper;
    property SnapshotState: TA2600CartridgeState read FState write FState;
  end;

implementation

uses
  System.Math;

function Signature(const Data: TBytes; const Bytes: array of Byte; Required: Integer = 1): Boolean;
begin
  Result := False;
  for var i := 0 to Length(Data) - Length(Bytes) do
    if CompareMem(@Data[i], @Bytes[0], Length(Bytes)) then
    begin
      Dec(Required);
      if Required = 0 then
        Exit(True);
    end;
end;

function CartridgePayloadSize(const Data: TBytes): Integer;
const
  Sizes: array[0..7] of Integer = (1024, 2048, 4096, 8192, 12288, 16384, 32768, 65536);
begin
  Result := Length(Data);
  for var Size in Sizes do
    if (Length(Data) > Size) and (Length(Data) <= Size + 16) then
    begin
      // Recognize dump padding and appended line endings, never missing bytes.
      // Both reset-vector bytes must already be present in the payload.
      var Vector := Word(Data[Size - 4]) or (Word(Data[Size - 3]) shl 8);
      if Vector and $1000 = 0 then
        Exit;
      var Padding := True;
      for var i := Size to High(Data) do
        if not (Data[i] in [$00, $FF]) then
          Padding := False;
      var LineEnding := (Length(Data) = Size + 2) and
        (Data[Size] = $0D) and (Data[Size + 1] = $0A);
      var RepeatedVector := (Length(Data) = Size + 2) and
        (Data[Size] = Data[Size - 2]) and (Data[Size + 1] = Data[Size - 1]);
      if Padding or LineEnding or RepeatedVector then
        Result := Size;
      Exit;
    end;
end;

function HasFALoaderBank(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) <> 16384 then
    Exit;
  // Some 12K CBS dumps append a 4K NOP bank with a tiny FA bank-select
  // loader. It is a dump wrapper, not a fourth game bank of an F6 cartridge.
  if (Data[$3200] <> $A9) or (Data[$3202] <> $8D) or
    (Data[$3203] <> $FA) or (Data[$3204] <> $1F) or
    (Data[$3FFC] <> $00) or (Data[$3FFD] <> $12) then
    Exit;
  for var i := $3000 to $3FFF do
    if not ((i >= $3200) and (i <= $3204)) and
      (i <> $3FFC) and (i <> $3FFD) and (Data[i] <> $EA) then
      Exit;
  Result := True;
end;

function Is16GameCartridge(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) <> 65536 then
    Exit;
  var TwoKEntries := 0;
  for var Bank := 0 to 31 do
  begin
    var P := Bank * 2048 + 2044;
    var Entry := Word(Data[P]) or (Word(Data[P + 1]) shl 8);
    var Valid := (Entry and $1000 <> 0) and (Entry <> $FFFF);
    if Valid then
      Inc(TwoKEntries)
    else if Bank and 1 <> 0 then
      Exit; // Every 4K game needs its own reset vector.
  end;
  // A 32-game 2K collection has vectors in both halves of each 4K window.
  Result := TwoKEntries < 28;
end;

constructor TA2600Cartridge.Create(const Data: TBytes; const Mapper: string);
const
  Names: array[TA2600Mapper] of string = ('2K', '4K', 'F8', 'F6', 'F4', 'E0', '3F', 'FA', 'E7', 'FE', 'UA', 'CV', '0840', 'MB', 'MC32', 'DPC', 'AR', 'CM', 'MC16');
begin
  inherited Create;
  FData := Copy(Data);
  if Mapper = '' then
    SetLength(FData, CartridgePayloadSize(FData));
  if ((Mapper = '') or SameText(Mapper, 'FA')) and HasFALoaderBank(FData) then
    SetLength(FData, 12288);
  // Remove exact repeated overdumps, keeping the original identity in the frontend.
  while (Mapper = '') and (Length(FData) >= 4096) and (Length(FData) mod 4096 = 0) and
      CompareMem(@FData[0], @FData[Length(FData) div 2], Length(FData) div 2) do
    SetLength(FData, Length(FData) div 2);
  if (Length(FData) = 6144) or ((Length(FData) > 0) and (Length(FData) mod 8448 = 0)) then
    FMapper := mAR
  else
    case Length(FData) of
      1024, 2048:
        FMapper := m2K;
      4096:
        FMapper := m4K;
      8192:
        FMapper := mF8;
      12288:
        FMapper := mFA;
      16384:
        FMapper := mF6;
      32768:
        FMapper := mF4;
      65536:
        FMapper := mMC32;
      10240..10496:
        FMapper := mDPC;
    else
      if (Length(FData) >= 4096) and (Length(FData) <= 512 * 1024) and
        (Length(FData) mod 2048 = 0) and Signature(FData, [$85, $3F], 2) then
        FMapper := m3F
      else
        raise EReadError.Create('Unsupported Atari 2600 cartridge size');
    end;
  if ((Length(FData) = 2048) or (Length(FData) = 4096)) and
    (Signature(FData, [$9D, $FF, $F3]) or Signature(FData, [$99, $00, $F4])) then
    FMapper := mCV;
  if Length(FData) = 8192 then
  begin
    // Indexed reads near the vectors are ordinary ROM data, not E0 evidence.
    if Signature(FData, [$8D, $E0, $1F]) or Signature(FData, [$8D, $E0, $5F]) or
      Signature(FData, [$8D, $E9, $FF]) or Signature(FData, [$0C, $E0, $1F]) or
      Signature(FData, [$AD, $E0, $1F]) or Signature(FData, [$AD, $E9, $FF]) or
      Signature(FData, [$AD, $ED, $FF]) or Signature(FData, [$AD, $F3, $BF]) then
      FMapper := mE0
    else if Signature(FData, [$85, $3F], 2) then
      FMapper := m3F
    else if Signature(FData, [$8D, $40, $02]) or Signature(FData, [$AD, $40, $02]) or
      Signature(FData, [$2C, $C0, $02]) then
      FMapper := mUA
    else if (Signature(FData, [$20, $00, $D0, $C6, $C5]) or
      Signature(FData, [$20, $C3, $F8, $A5, $82]) or Signature(FData, [$D0, $FB, $20, $73, $FE]) or
      Signature(FData, [$D0, $FB, $20, $68, $FE]) or Signature(FData, [$20, $00, $F0, $84, $D6])) and
      not Signature(FData, [$8D, $F9, $1F], 2) then
      FMapper := mFE
    else if Signature(FData, [$AD, $00, $08]) and Signature(FData, [$AD, $40, $08]) then
      FMapper := m0840;
  end;
  if (Length(FData) = 16384) or (Length(FData) = 12288) then
    if Signature(FData, [$AD, $E2, $FF]) or Signature(FData, [$AD, $E5, $FF]) or
      Signature(FData, [$AD, $E5, $1F]) or Signature(FData, [$AD, $E7, $1F]) or
      Signature(FData, [$0C, $E7, $1F]) or Signature(FData, [$8D, $E7, $FF]) or
      Signature(FData, [$8D, $E7, $1F]) then
      FMapper := mE7;
  if (Length(FData) >= 32768) and Signature(FData, [$85, $3F], 2) then
    FMapper := m3F;
  if Is16GameCartridge(FData) then
    FMapper := mMC16;
  if (Length(FData) = 65536) and (Signature(FData, [$AD, $F0, $FF], 2) or
    Signature(FData, [$8D, $F0, $FF], 2) or Signature(FData, [$0C, $F0, $FF], 2)) then
    FMapper := mMB;
  // CompuMate selects its four ROM banks repeatedly through RIOT's SWCHA.
  if (Length(FData) = 16384) and Signature(FData, [$8D, $80, $02], 8) then
    FMapper := mCM;
  if Mapper <> '' then
  begin
    var Found := False;
    for var M := Low(TA2600Mapper) to High(TA2600Mapper) do
      if SameText(Mapper, Names[M]) or SameText(Mapper, Names[M] + 'SC') then
      begin
        FMapper := M;
        Found := True;
      end;
    if not Found then
      raise EReadError.Create('Unsupported Atari 2600 mapper: ' + Mapper);
  end;
  if ((FMapper = m2K) and (Length(FData) <> 1024) and (Length(FData) <> 2048)) or
    ((FMapper = m4K) and (Length(FData) <> 4096)) or
    ((FMapper in [mF8, mE0, mFE, mUA, m0840]) and (Length(FData) <> 8192)) or
    ((FMapper = mF6) and (Length(FData) <> 16384)) or
    ((FMapper = mF4) and (Length(FData) <> 32768)) or
    ((FMapper = mFA) and (Length(FData) <> 12288)) or
    ((FMapper = mCM) and (Length(FData) <> 16384)) or
    ((FMapper in [mMB, mMC32, mMC16]) and (Length(FData) <> 65536)) or
    ((FMapper = mCV) and (Length(FData) <> 2048) and (Length(FData) <> 4096)) or
    ((FMapper = m3F) and ((Length(FData) < 4096) or (Length(FData) mod 2048 <> 0))) or
    ((FMapper = mE7) and (Length(FData) <> 8192) and (Length(FData) <> 12288) and (Length(FData) <> 16384)) then
    raise EReadError.Create('Atari cartridge mapper/size mismatch');
  FSuperchip := FMapper in [mF8, mF6, mF4];
  if FSuperchip then
    for var B := 0 to Length(FData) div 4096 - 1 do
      for var i := 0 to 127 do
        if FData[B * 4096 + i] <> FData[B * 4096 + 128 + i] then
          FSuperchip := False;
  if Mapper.ToUpper.EndsWith('SC') then
    FSuperchip := True;
  if FMapper = mDPC then
    FDPC := TA2600DPC.Create(FData);
  if FMapper = mAR then
    FSupercharger := TA2600Supercharger.Create(FData);
  Reset;
end;

destructor TA2600Cartridge.Destroy;
begin
  FSupercharger.Free;
  FDPC.Free;
  inherited;
end;

procedure TA2600Cartridge.Clock(CPUFrequency: Double);
begin
  if FDPC <> nil then
    FDPC.Clock(CPUFrequency);
end;

procedure TA2600Cartridge.Reset;
begin
  if FSupercharger <> nil then
    FSupercharger.Reset;
  if FDPC <> nil then
    FDPC.Reset;
  FillChar(FState, SizeOf(FState), 0);
  FState.Bank := Max(0, Length(FData) div 4096 - 1);
  FillChar(FExtraRAM, SizeOf(FExtraRAM), 0);
  FRAMBank := 0;
  FSWCHA := $FF;
  FFEPending := False;
  if FMapper in [mFE, mE7, mUA, mMC32, mMC16] then
    FState.Bank := 0;
  if FMapper = mF6 then
  begin
    // F6 has no guaranteed last-bank power-on state. Prefer an explicit
    // cold-start stub in bank 0; retain the usual last-bank default otherwise.
    var Entry := Word(FData[$FFC]) or (Word(FData[$FFD]) shl 8);
    var Offset := Entry and $FFF;
    if (Entry and $1000 <> 0) and (Offset < $FFF) and
      (((FData[Offset] = $78) and (FData[Offset + 1] = $D8)) or
      ((FData[Offset] = $D8) and (FData[Offset + 1] = $78))) then
      FState.Bank := 0;
  end;
  if (FMapper = mCV) and (Length(FData) = 4096) then
    Move(FData[0], FExtraRAM[0], 1024);
  FState.Segments[0] := 4;
  FState.Segments[1] := 5;
  FState.Segments[2] := 6;
end;

procedure TA2600Cartridge.Hotspot(Address: Word; Value: Byte; Writing: Boolean);
begin
  if FSupercharger <> nil then
    FSupercharger.Access(Address);
  case FMapper of
    mF8, mDPC:
      if (Address >= $1FF8) and (Address <= $1FF9) then
        FState.Bank := Address - $1FF8;
    mF6:
      if (Address >= $1FF6) and (Address <= $1FF9) then
        FState.Bank := Address - $1FF6;
    mF4:
      if (Address >= $1FF4) and (Address <= $1FFB) then
        FState.Bank := Address - $1FF4;
    mFA:
      if (Address >= $1FF8) and (Address <= $1FFA) then
        FState.Bank := Address - $1FF8;
    mE0:
      if (Address >= $1FE0) and (Address <= $1FF7) then
        FState.Segments[(Address - $1FE0) div 8] := Address and 7;
    m3F:
      if Writing and (Address <= $3F) then
        FState.Bank := Value mod (Length(FData) div 2048);
    mE7:
      begin
        if (Address >= $1FE0) and (Address <= $1FE7) then
        begin
          var N := Length(FData) div 2048;
          if N = 4 then
          begin
            if Address >= $1FE4 then
              FState.Bank := Address and 3;
          end
          else if N = 6 then
          begin
            if Address and 7 < 2 then
              FState.Bank := Address and 1
            else
              FState.Bank := (Address and 7) - 2;
          end
          else
            FState.Bank := Address and 7;
        end;
        if (Address >= $1FE8) and (Address <= $1FEB) then
          FRAMBank := Address and 3;
      end;
    mCM:
      if Writing and (Address = $280) then
      begin
        FSWCHA := Value;
        FState.Bank := Value and 3;
      end;
    mUA:
      case Address and $1260 of
        $220:
          FState.Bank := 0;
        $240:
          FState.Bank := 1;
      end;
    m0840:
      if Address and $1800 = $0800 then
        FState.Bank := (Address shr 6) and 1;
    mMB:
      if Address = $1FF0 then
        FState.Bank := (FState.Bank + 1) mod (Length(FData) div 4096);
  end;
end;

function TA2600Cartridge.Read(Address: Word): Byte;
begin
  var A := Address and $FFF;
  if FSupercharger <> nil then
    Exit(FSupercharger.Read(Address));
  if FDPC <> nil then
  begin
    FDPC.Access;
    if A < $40 then
      Exit(FDPC.Read(A));
  end;
  if FSuperchip and (A in [$80..$FF]) then
    Exit(FState.RAM[A and 127]);
  if (FMapper = mFA) and (A >= $100) and (A < $200) then
    Exit(FState.FARAM[A and 255]);
  case FMapper of
    m2K:
      Result := FData[A mod Length(FData)];
    m4K:
      Result := FData[A];
    mCM:
      if (A >= $800) and (FSWCHA and $10 = 0) then
        Result := FExtraRAM[A and $7FF]
      else
        Result := FData[FState.Bank * 4096 + A];
    mMC32:
      Result := FData[FState.Bank * 2048 + (A and $7FF)];
    mCV:
      if A < $800 then
        Result := FExtraRAM[A and $3FF]
      else
        Result := FData[Length(FData) - 2048 + (A and $7FF)];
    mE7:
      if (A < $800) and (FState.Bank = Length(FData) div 2048 - 1) then
        Result := FExtraRAM[A and $3FF]
      else if (A >= $800) and (A < $A00) then
        Result := FExtraRAM[1024 + FRAMBank * 256 + (A and $FF)]
      else if A < $800 then
        Result := FData[FState.Bank * 2048 + A]
      else
        Result := FData[Length(FData) - 2048 + (A and $7FF)];
    mE0:
      if A < $C00 then
        Result := FData[FState.Segments[A div 1024] * 1024 + (A and 1023)]
      else
        Result := FData[7168 + (A and 1023)];
    m3F:
      if A < $800 then
        Result := FData[FState.Bank * 2048 + (A and 2047)]
      else
        Result := FData[Length(FData) - 2048 + (A and 2047)];
  else
    Result := FData[FState.Bank * 4096 + A];
  end;
end;

procedure TA2600Cartridge.Write(Address: Word; Value: Byte);
begin
  var A := Address and $FFF;
  if FDPC <> nil then
  begin
    FDPC.Access;
    if (A >= $40) and (A < $80) then
      FDPC.Write(A, Value);
  end;
  if (FMapper = mCM) and (A >= $800) and (FSWCHA and $30 = $20) then
    FExtraRAM[A and $7FF] := Value;
  if (FMapper = mCV) and (A >= $400) and (A < $800) then
    FExtraRAM[A and $3FF] := Value;
  if FMapper = mE7 then
    if (A < $400) and (FState.Bank = Length(FData) div 2048 - 1) then
      FExtraRAM[A] := Value
    else if (A >= $800) and (A < $900) then
      FExtraRAM[1024 + FRAMBank * 256 + (A and $FF)] := Value;
  if FSuperchip and (Address and $FFF < $80) then
    FState.RAM[Address and 127] := Value;
  if (FMapper = mFA) and (Address and $FFF < $100) then
    FState.FARAM[Address and 255] := Value;
end;

procedure TA2600Cartridge.Observe(Address: Word; Value: Byte);
begin
  if FSupercharger <> nil then
    FSupercharger.Observe(Address, Value);
  if FMapper <> mFE then
    Exit;
  if FFEPending then
  begin
    FState.Bank := ((Value shr 5) xor 1) and 1;
    FFEPending := False;
  end
  else
    FFEPending := Address = $01FE;
end;

procedure TA2600Cartridge.SerializeExtra(State: TStateArchive);
begin
  if FSupercharger <> nil then
    FSupercharger.SerializeState(State);
  if FDPC <> nil then
    FDPC.SerializeState(State);
  State.Field(FExtraRAM, SizeOf(FExtraRAM));
  State.Field(FRAMBank, SizeOf(FRAMBank));
  State.Field(FSWCHA, SizeOf(FSWCHA));
  State.Field(FFEPending, SizeOf(FFEPending));
  if (FRAMBank < 0) or (FRAMBank > 3) then
    raise EReadError.Create('Invalid cartridge RAM bank');
end;

procedure TA2600Cartridge.ValidateState;
begin
  var Banks := Max(1, Length(FData) div 4096);
  if FMapper in [m3F, mE7, mMC32] then
    Banks := Length(FData) div 2048;
  if (FState.Bank < 0) or (FState.Bank >= Banks) then
    raise EReadError.Create('Invalid Atari 2600 cartridge bank');
  for var i := 0 to High(FState.Segments) do
    if (FState.Segments[i] < 0) or (FState.Segments[i] > 7) then
      raise EReadError.Create('Invalid Atari 2600 segment');
end;

end.

