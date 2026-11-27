unit INTV.Cartridge;

interface

uses
  System.SysUtils, Core.Snapshots, INTV.JLP, INTV.Locutus;

type
  TIntvKiosk = class
  private
    FROM: array[0..$7FF] of Word;
    FSlots: array[0..10] of TArray<Word>;
    FSelected: Integer;
    FTimer: Int64;
    FResetPending: Boolean;
  public
    constructor Create(const Image: TBytes);
    class function IsImage(const Data: TBytes): Boolean; static;
    procedure Reset;
    function ReadWord(Address: Word): Word;
    procedure WriteWord(Address: Word);
    procedure Advance(Cycles, CPUHz: Integer);
    procedure SerializeState(State: TStateArchive);
    property SelectedSlot: Integer read FSelected;
    property ResetPending: Boolean read FResetPending;
  end;

  TIntvCartridge = class
  private
    type
      TPagedMemory = record
        Image, Memory: TArray<Word>;
        Access: TBytes;
      end;

      PPagedMemory = ^TPagedMemory;
  private
    const
      Readable = 1;
      Writable = 2;
      Narrow = 4;
      Banked = 8;
  private
    FImage, FMemory: array[Word] of Word;
    FAccess: array[Word] of Byte;
    FBanks: array[0..31] of Word;
    FHasBanks: Boolean;
    FJLP: TIntvJLP;
    FLocutus: TIntvLocutus;
    FKiosk: TIntvKiosk;
    FJLPMode, FFlashSectors: Integer;
    FECSCompatibility, FVoiceCompatibility: Integer;
    FPages: array[0..15, 0..15] of TPagedMemory;
    FPageSelect: array[0..15] of Byte;
    FPageWindows: set of 0..15;
    procedure LoadCompatibilityTags(const Data: TBytes; Offset: Integer);
    procedure ResetPages;
    procedure ConfigurePages(Page, First, Last: Integer; Attributes: Byte);
    procedure LoadPages(const Data: TBytes; Page, First, Last, Address: Integer; Attributes: Byte);
    procedure LoadSegmented(const Data: TBytes);
    procedure LoadRaw(const Data: TBytes; const Config: string);
    function PhysicalAddress(Address: Word; Access: Byte): Word;
  public
    constructor CreateEmpty;
    constructor Create(const Data: TBytes; const Config: string);
    destructor Destroy; override;
    property Kiosk: TIntvKiosk read FKiosk;
    property Locutus: TIntvLocutus read FLocutus;
    property JLP: TIntvJLP read FJLP;
    property ECSCompatibility: Integer read FECSCompatibility;
    property VoiceCompatibility: Integer read FVoiceCompatibility;
    class function HasContainerHeader(const Data: TBytes): Boolean; static;
    procedure Reset;
    function ReadWord(Address: Word): Word;
    function HasExtendedCPU: Boolean;
    function ExtendedPortsVisible: Boolean;
    function TryPreviousValue(Address: Word; out Value: Word): Boolean;
    procedure WriteWord(Address, Value: Word);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math, System.RegularExpressions, INTV.LuigiImage;

function CRC16(const Data: TBytes; Offset, Count: Integer): Word;
begin
  Result := $FFFF;
  for var Index := Offset to Offset + Count - 1 do
  begin
    Result := Result xor (Data[Index] shl 8);
    for var Bit := 0 to 7 do
      if Result and $8000 <> 0 then
        Result := Word(Result shl 1) xor $1021
      else
        Result := Word(Result shl 1);
  end;
end;

class function TIntvKiosk.IsImage(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 4) and (Data[0] = Ord('K')) and (Data[1] = Ord('I')) and
    (Data[2] = Ord('O')) and (Data[3] = Ord('S'));
end;

constructor TIntvKiosk.Create(const Image: TBytes);
begin
  inherited Create;
  if not IsImage(Image) or (Length(Image) < 8 + SizeOf(FROM)) then
    raise EReadError.Create('Truncated Intellivision kiosk image');
  if (Image[4] <> 0) or (Image[5] <> 1) then
    raise EReadError.Create('Unsupported Intellivision kiosk image version');
  var Slots := (Word(Image[6]) shl 8) or Image[7];
  if Slots and $F800 <> 0 then
    raise EReadError.Create('Invalid Intellivision kiosk slot mask');
  var ExpectedSize := 8 + SizeOf(FROM);
  for var Slot := 0 to High(FSlots) do
    if Slots and (1 shl Slot) <> 0 then
      Inc(ExpectedSize, $4000);
  if Length(Image) <> ExpectedSize then
    raise EReadError.Create('Invalid Intellivision kiosk image length');
  var Position := 8;
  for var Index := 0 to High(FROM) do
  begin
    FROM[Index] := (Word(Image[Position]) shl 8) or Image[Position + 1];
    Inc(Position, 2);
  end;
  for var Slot := 0 to High(FSlots) do
    if Slots and (1 shl Slot) <> 0 then
    begin
      SetLength(FSlots[Slot], $2000);
      for var Index := 0 to High(FSlots[Slot]) do
      begin
        FSlots[Slot][Index] := (Word(Image[Position]) shl 8) or Image[Position + 1];
        Inc(Position, 2);
      end;
    end;
  Reset;
end;

procedure TIntvKiosk.Reset;
begin
  FSelected := -1;
  FTimer := 0;
  FResetPending := False;
end;

function TIntvKiosk.ReadWord(Address: Word): Word;
begin
  if (Address >= $7000) and (Address <= $77FF) then
    Exit(FROM[Address - $7000]);
  if (Address >= $5000) and (Address <= $6FFF) and (FSelected >= 0) and
    (FSlots[FSelected] <> nil) then
    Exit(FSlots[FSelected][Address - $5000]);
  Result := $FFFF;
end;

procedure TIntvKiosk.WriteWord(Address: Word);
begin
  // Rev D decodes A15..A12, A10 and A7..A0. The write data is unconnected.
  if Address and $F400 <> $7400 then
    Exit;
  var Register := Address and $FF;
  if Register = 0 then
    FSelected := -1
  else if (Register >= $10) and (Register <= $1A) then
    FSelected := Register - $10;
  // Slot 1 retriggers the 556 and can run the attract cartridge indefinitely.
  if FSelected = 0 then
    FTimer := 0;
end;

procedure TIntvKiosk.Advance(Cycles, CPUHz: Integer);
begin
  if (FSelected = 0) or FResetPending then
    Exit;
  Inc(FTimer, Cycles);
  // Nominal measured Rev D period. Individual analog timers vary.
  if FTimer >= Int64(CPUHz) * 480 then
    FResetPending := True;
end;

procedure TIntvKiosk.SerializeState(State: TStateArchive);
begin
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FResetPending, SizeOf(FResetPending));
  if (FSelected < -1) or (FSelected > High(FSlots)) or (FTimer < 0) or
    (FTimer > Int64(1000000) * 481) then
    raise EReadError.Create('Invalid Intellivision kiosk state');
end;

class function TIntvCartridge.HasContainerHeader(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 53) and (Data[0] in [$A8, $41, $61]) and
    (Data[1] xor Data[2] = $FF);
  Result := Result or TLuigiImage.IsContainer(Data) or TIntvKiosk.IsImage(Data);
end;

constructor TIntvCartridge.CreateEmpty;
begin
  inherited Create;
end;

constructor TIntvCartridge.Create(const Data: TBytes; const Config: string);
begin
  inherited Create;
  FVoiceCompatibility := 1;
  if TIntvKiosk.IsImage(Data) then
  begin
    FKiosk := TIntvKiosk.Create(Data);
    Exit;
  end;
  if TLuigiImage.IsContainer(Data) then
  begin
    var Image := TLuigiImage.Decode(Data);
    FLocutus := TIntvLocutus.Create(Image);
    FECSCompatibility := Image.ECSCompatibility;
    FVoiceCompatibility := Image.VoiceCompatibility;
    if Image.JLPMode <> 0 then
      FJLP := TIntvJLP.Create(Image.JLPMode, Image.JLPFlashSectors, FLocutus.Memory);
    Exit;
  end;
  FillChar(FImage, SizeOf(FImage), $FF);
  if HasContainerHeader(Data) then
    LoadSegmented(Data)
  else
    LoadRaw(Data, Config);
  if FJLPMode <> 0 then
    FJLP := TIntvJLP.Create(FJLPMode, FFlashSectors);
  Reset;
end;

destructor TIntvCartridge.Destroy;
begin
  FKiosk.Free;
  FJLP.Free;
  FLocutus.Free;
  inherited;
end;

procedure TIntvCartridge.LoadCompatibilityTags(const Data: TBytes; Offset: Integer);
const
  Compatibility: array[0..3] of Integer = (1, 2, 3, 0);
begin
  while Offset + 4 <= Length(Data) do
  begin
    var Start := Offset;
    var Header := Data[Offset];
    Inc(Offset);
    var Extra := Header shr 6;
    if Length(Data) - Offset < Extra + 3 then
      Exit;
    var Count := Integer(Header and $3F);
    for var Index := 0 to Extra - 1 do
    begin
      Inc(Count, Integer(Data[Offset]) shl (6 + Index * 8));
      Inc(Offset);
    end;
    var Tag := Data[Offset];
    Inc(Offset);
    if Count > Length(Data) - Offset - 2 then
      Exit;
    var EndOfPayload := Offset + Count;
    if CRC16(Data, Start, EndOfPayload - Start) <>
      ((Data[EndOfPayload] shl 8) or Data[EndOfPayload + 1]) then
      Exit;

    if (Tag = $06) and (Count >= 3) then
    begin
      FECSCompatibility := Compatibility[Data[Offset] shr 6];
      FVoiceCompatibility := Compatibility[(Data[Offset] shr 2) and 3];
      if Count >= 4 then
      begin
        FJLPMode := Data[Offset + 3] shr 6;
        if Count >= 5 then
          FFlashSectors := ((Data[Offset + 3] and 3) shl 8) or Data[Offset + 4];
      end;
    end;
    Offset := EndOfPayload + 2;
  end;
end;

procedure TIntvCartridge.LoadSegmented(const Data: TBytes);
begin
  var Offset := 3;
  for var Segment := 1 to Data[1] do
  begin
    var Start := Offset;
    if Offset + 4 > Length(Data) then
      raise EReadError.Create('Truncated Intellivision ROM segment');
    var First := Integer(Data[Offset]) shl 8;
    var Last := (Integer(Data[Offset + 1]) + 1) shl 8;
    Inc(Offset, 2);
    var Size := (Last - First) * 2;
    if (Size <= 0) or (Offset + Size + 2 > Length(Data)) then
      raise EReadError.Create('Invalid Intellivision ROM segment range');
    for var Address := First to Last - 1 do
    begin
      FImage[Address] := (Data[Offset] shl 8) or Data[Offset + 1];
      Inc(Offset, 2);
    end;
    if CRC16(Data, Start, Size + 2) <> ((Data[Offset] shl 8) or Data[Offset + 1]) then
      raise EReadError.Create('Invalid Intellivision ROM segment checksum');
    Inc(Offset, 2);
  end;
  if Offset + 50 > Length(Data) then
    raise EReadError.Create('Truncated Intellivision ROM attributes');
  if CRC16(Data, Offset, 48) <> ((Data[Offset + 48] shl 8) or Data[Offset + 49]) then
    raise EReadError.Create('Invalid Intellivision ROM attribute checksum');
  for var Bank := 0 to 31 do
  begin
    var Attributes := (Data[Offset + Bank div 2] shr ((Bank and 1) * 4)) and 15;
    var RangeByte := Data[Offset + 16 + Bank div 2 + (Bank and 1) * 16];
    var FirstPage := (RangeByte shr 4) and 7;
    var LastPage := RangeByte and 7;
    if (Attributes <> 0) and (FirstPage > LastPage) then
      raise EReadError.Create('Invalid Intellivision ROM attribute range');
    for var Page := FirstPage to LastPage do
      FillChar(FAccess[(Bank * 8 + Page) * 256], 256, Attributes);
    if Attributes and Banked <> 0 then
      FHasBanks := True;
  end;
  LoadCompatibilityTags(Data, Offset + 50);
end;

procedure TIntvCartridge.ConfigurePages(Page, First, Last: Integer; Attributes: Byte);
begin
  if (Page < 0) or (Page > 15) or (First < 0) or (Last < First) or (Last > $FFFF) then
    raise EReadError.Create('Invalid Intellivision cartridge page range');
  for var Window := First shr 12 to Last shr 12 do
  begin
    Include(FPageWindows, Window);
    var Bank: PPagedMemory := @FPages[Window, Page];
    if Bank.Image = nil then
    begin
      SetLength(Bank.Image, $1000);
      FillChar(Bank.Image[0], $1000 * SizeOf(Word), $FF);
      SetLength(Bank.Access, $1000);
    end;
    var Start := Max(First - (Window shl 12), 0);
    var Stop := Min(Last - (Window shl 12), $FFF);
    FillChar(Bank.Access[Start], Stop - Start + 1, Attributes);
  end;
end;

procedure TIntvCartridge.LoadPages(const Data: TBytes; Page, First, Last, Address: Integer; Attributes: Byte);
begin
  if (Page < 0) or (Page > 15) or (First < 0) or (Last < First) or
    (Address < 0) or (Address > $FFFF) or (Last - First > $FFFF - Address) then
    raise EReadError.Create('Invalid Intellivision cartridge page mapping');
  var DataLast := Min(Last, Length(Data) div 2 - 1);
  var MappedLast := DataLast;
  if Attributes and Writable <> 0 then
    MappedLast := Last;
  if MappedLast < First then
    Exit;
  ConfigurePages(Page, Address, Address + (MappedLast - First), Attributes);
  for var Index := First to DataLast do
  begin
    FPages[Address shr 12, Page].Image[Address and $FFF] :=
      (Data[Index * 2] shl 8) or Data[Index * 2 + 1];
    Inc(Address);
  end;
end;

procedure TIntvCartridge.LoadRaw(const Data: TBytes; const Config: string);

  function Hex(const Value: string): Integer;
  begin
    if not TryStrToInt('$' + Value.TrimLeft(['$']), Result) or (Result < 0) then
      raise EReadError.Create('Invalid Intellivision cartridge address: ' + Value);
  end;

  function OptionalGroup(const Match: TMatch; Index: Integer): string;
  begin
    Result := '';
    if Index < Match.Groups.Count then
      Result := Match.Groups[Index].Value;
  end;

  function PageNumber(const Value: string): Integer;
  begin
    Result := -1;
    if Value <> '' then
      Result := Hex(Value);
  end;

  function MemoryAttributes(const Kind, Width: string): Byte;
  begin
    Result := Readable;
    if SameText(Kind, 'RAM') then
      Result := Readable or Writable
    else if SameText(Kind, 'WOM') then
      Result := Writable;
    if Width = '8' then
      Result := Result or Narrow;
  end;

  procedure MapWords(First, Last, Address: Integer; Attributes: Byte);
  begin
    if (First < 0) or (Last < First) or
      (Address < 0) or (Address > $FFFF) or (Last - First > $FFFF - Address) then
      raise EReadError.Create('Invalid Intellivision cartridge mapping');
    var DataLast := Min(Last, Length(Data) div 2 - 1);
    for var Index := First to DataLast do
    begin
      FImage[Address] := (Data[Index * 2] shl 8) or Data[Index * 2 + 1];
      FAccess[Address] := FAccess[Address] or Attributes;
      Inc(Address);
    end;
    // A CFG may describe the capacity of the board beyond the end of the BIN.
    // Omit absent ROM words, but keep the writable part of the address range.
    if Attributes and Writable <> 0 then
      for var Target := Address to Address + (Last - Max(First, DataLast + 1)) do
        FAccess[Target] := FAccess[Target] or Attributes;
  end;

  procedure MapDefault;
  begin
    var Count := Length(Data) div 2;
    if Count > $4000 then
      raise EReadError.Create('Large raw Intellivision cartridges need a .cfg mapping');
    MapWords(0, Min(Count, $2000) - 1, $5000, Readable);
    if Count > $2000 then
      MapWords($2000, Min(Count, $3000) - 1, $D000, Readable);
    if Count > $3000 then
      MapWords($3000, Count - 1, $F000, Readable);
  end;

begin
  if (Length(Data) < 2) or Odd(Length(Data)) or (Length(Data) > $200000) then
    raise EReadError.Create('Invalid Intellivision cartridge size');
  if Config.Trim = '' then
  begin
    MapDefault;
    Exit;
  end;

  var Lines := TStringList.Create;
  try
    Lines.Text := Config;
    var Section := '';
    var Mapped := False;
    var ExplicitVoiceCompatibility := False;
    const HexField = '(\$?[0-9a-f]+)';
    const Span = HexField + '\s*-\s*' + HexField;
    const PageSuffix = '(?:PAGE\s+' + HexField + '\s*)?';
    const AttributesSuffix = '(?:(RAM|ROM|WOM)\s+(8|16)\s*)?';
    var Mapping := TRegEx.Create('^' + Span + '\s*=\s*' + HexField + '\s*' +
      PageSuffix + AttributesSuffix + '$', [roIgnoreCase]);
    var LegacyPages := TRegEx.Create('^' + HexField + '\s*:\s*' + Span + '\s*=\s*' +
      HexField + '$', [roIgnoreCase]);
    var Memory := TRegEx.Create('^' + Span + '(?:\s*=\s*' + PageSuffix +
      AttributesSuffix + ')?$', [roIgnoreCase]);
    for var Line in Lines do
    begin
      var Comment := Pos(';', Line);
      var Text := Line;
      if Comment > 0 then
        Text := Copy(Line, 1, Comment - 1);
      Text := Text.Trim;
      if Text = '' then
        Continue;
      if Text.StartsWith('[') then
      begin
        Section := Text.ToLower;
        Continue;
      end;
      if Section = '[vars]' then
      begin
        var Equals := Pos('=', Text);
        if Equals = 0 then
          Continue;
        var Key := Copy(Text, 1, Equals - 1).Trim.ToLower;
        var Value: Integer;
        if not TryStrToInt(Copy(Text, Equals + 1).Trim, Value) then
          Continue;
        if (Key = 'jlp_accel') or (Key = 'jlp') then
          FJLPMode := EnsureRange(Value, 0, 3)
        else if (Key = 'jlp_flash') or (Key = 'jlpflash') then
          FFlashSectors := EnsureRange(Value, 0, 1023)
        else if Key = 'ecs_compat' then
          FECSCompatibility := EnsureRange(Value, 0, 3)
        else if Key = 'voice_compat' then
        begin
          FVoiceCompatibility := EnsureRange(Value, 0, 3);
          ExplicitVoiceCompatibility := True;
        end
        else if (Key = 'voice') and not ExplicitVoiceCompatibility then
          FVoiceCompatibility := 1 + Ord(Value <> 0);
      end
      else if (Section = '[mapping]') or (Section = '[preload]') then
      begin
        var Match := Mapping.Match(Text);
        if not Match.Success then
          raise EReadError.Create('Unsupported Intellivision cartridge mapping: ' + Text);
        var First := Hex(Match.Groups[1].Value);
        var Last := Hex(Match.Groups[2].Value);
        var Address := Hex(Match.Groups[3].Value);
        var Page := PageNumber(OptionalGroup(Match, 4));
        var Attributes := MemoryAttributes(OptionalGroup(Match, 5), OptionalGroup(Match, 6));
        if Section = '[preload]' then
          Attributes := 0;
        if Page >= 0 then
          LoadPages(Data, Page, First, Last, Address, Attributes)
        else
          MapWords(First, Last, Address, Attributes);
        Mapped := True;
      end
      else if Section = '[ecsbank]' then
      begin
        var Match := LegacyPages.Match(Text);
        if not Match.Success then
          raise EReadError.Create('Invalid Intellivision cartridge bank: ' + Text);
        LoadPages(Data, Hex(Match.Groups[1].Value), Hex(Match.Groups[2].Value),
          Hex(Match.Groups[3].Value), Hex(Match.Groups[4].Value), Readable);
        Mapped := True;
      end
      else if (Section = '[memattr]') or (Section = '[bankswitch]') then
      begin
        var Match := Memory.Match(Text);
        if not Match.Success then
          raise EReadError.Create('Unsupported Intellivision cartridge attributes: ' + Text);
        var First := Hex(Match.Groups[1].Value);
        var Last := Hex(Match.Groups[2].Value);
        if (Last < First) or (Last > $FFFF) then
          raise EReadError.Create('Invalid Intellivision cartridge attribute range');
        if Section = '[bankswitch]' then
        begin
          for var Address := First to Last do
            FAccess[Address] := FAccess[Address] or Banked or Readable;
          FHasBanks := True;
        end
        else
        begin
          var Page := PageNumber(OptionalGroup(Match, 3));
          var Attributes := MemoryAttributes(OptionalGroup(Match, 4), OptionalGroup(Match, 5));
          if Page >= 0 then
            ConfigurePages(Page, First, Last, Attributes)
          else
            for var Address := First to Last do
              FAccess[Address] := (FAccess[Address] and Banked) or Attributes;
        end;
      end;
    end;
    if not Mapped then
      MapDefault;
  finally
    Lines.Free;
  end;
end;

procedure TIntvCartridge.Reset;
begin
  if FKiosk <> nil then
    FKiosk.Reset;
  if FJLP <> nil then
    FJLP.Reset;
  if FLocutus <> nil then
  begin
    FLocutus.Reset;
    Exit;
  end;
  FMemory := FImage;
  FillChar(FBanks, SizeOf(FBanks), 0);
  ResetPages;
end;

procedure TIntvCartridge.ResetPages;
begin
  FillChar(FPageSelect, SizeOf(FPageSelect), 0);
  for var Window := Low(FPageSelect) to High(FPageSelect) do
    if Window in FPageWindows then
      for var Page := 0 to 15 do
        FPages[Window, Page].Memory := Copy(FPages[Window, Page].Image);
end;

function TIntvCartridge.PhysicalAddress(Address: Word; Access: Byte): Word;
begin
  Result := Address;
  if Access and Banked <> 0 then
    Result := Word(Address + FBanks[Address shr 11]);
end;

function TIntvCartridge.HasExtendedCPU: Boolean;
begin
  Result := (FJLP <> nil) or ((FLocutus <> nil) and FLocutus.MapperEnabled);
end;

function TIntvCartridge.ExtendedPortsVisible: Boolean;
begin
  if FJLP <> nil then
    Result := FJLP.ExtendedPortsVisible
  else
    Result := (FLocutus <> nil) and FLocutus.MapperEnabled;
end;

function TIntvCartridge.TryPreviousValue(Address: Word; out Value: Word): Boolean;
begin
  if (FJLP <> nil) and FJLP.Enabled and (Address >= $8000) and (Address <= $9FFF) then
    Exit(FJLP.TryPreviousValue(Address, Value));
  if FLocutus <> nil then
    Exit(FLocutus.TryPreviousValue(Address, Value));

  var Window := Address shr 12;
  if Window in FPageWindows then
  begin
    var Bank: PPagedMemory := @FPages[Window, FPageSelect[Window]];
    var Offset := Address and $FFF;
    if (Bank.Access <> nil) and (Bank.Access[Offset] and (Readable or Writable) <> 0) then
    begin
      Value := Bank.Memory[Offset];
      Exit(True);
    end;
  end;
  var Access := FAccess[Address];
  Result := Access and (Readable or Writable) <> 0;
  if Result then
    Value := FMemory[PhysicalAddress(Address, Access)];
end;

function TIntvCartridge.ReadWord(Address: Word): Word;
begin
  if FKiosk <> nil then
    Exit(FKiosk.ReadWord(Address));
  if (FJLP <> nil) and (Address >= $8000) and (Address <= $9FFF) and
    FJLP.ReadWord(Address, Result) then
    Exit;
  if FLocutus <> nil then
    Exit(FLocutus.ReadWord(Address));
  var Window := Address shr 12;
  if Window in FPageWindows then
  begin
    var Bank: PPagedMemory := @FPages[Window, FPageSelect[Window]];
    var Offset := Address and $FFF;
    if (Bank.Access <> nil) and (Bank.Access[Offset] and Readable <> 0) then
    begin
      Result := Bank.Memory[Offset];
      if Bank.Access[Offset] and Narrow <> 0 then
        Result := Result and $FF;
      Exit;
    end;
  end;
  var Access := FAccess[Address];
  if Access and Readable = 0 then
    Exit($FFFF);
  Result := FMemory[PhysicalAddress(Address, Access)];
  if Access and Narrow <> 0 then
    Result := Result and $FF;
end;

procedure TIntvCartridge.WriteWord(Address, Value: Word);
begin
  if FKiosk <> nil then
  begin
    FKiosk.WriteWord(Address);
    Exit;
  end;
  if (FJLP <> nil) and (Address >= $8000) and (Address <= $9FFF) and
    FJLP.WriteWord(Address, Value) then
    Exit;
  if FLocutus <> nil then
  begin
    FLocutus.WriteWord(Address, Value);
    Exit;
  end;
  var Window := Address shr 12;
  if Window in FPageWindows then
  begin
    if (Address and $FFF = $FFF) and (Value and $FFF0 = ((Window shl 12) or $A50)) then
    begin
      FPageSelect[Window] := Value and $F;
      Exit;
    end;
    var Bank: PPagedMemory := @FPages[Window, FPageSelect[Window]];
    var Offset := Address and $FFF;
    if (Bank.Access <> nil) and (Bank.Access[Offset] and Writable <> 0) then
    begin
      if Bank.Access[Offset] and Narrow <> 0 then
        Value := Value and $FF;
      Bank.Memory[Offset] := Value;
      Exit;
    end;
  end;
  if FHasBanks and (Address >= $40) and (Address <= $5F) then
  begin
    var Base := ((Address and 15) shl 12) or ((Address and $10) shl 7);
    if FAccess[Base] and Banked <> 0 then
      FBanks[Base shr 11] := Word(((Value and $FF) shl 8) - Base);
  end;
  var Access := FAccess[Address];
  if Access and Writable = 0 then
    Exit;
  if Access and Narrow <> 0 then
    Value := Value and $FF;
  FMemory[PhysicalAddress(Address, Access)] := Value;
end;

procedure TIntvCartridge.SerializeState(State: TStateArchive);
begin
  if FKiosk <> nil then
  begin
    if (State.Version <> 0) and (State.Version < 8) then
      raise EReadError.Create('Snapshot lacks Intellivision kiosk state');
    FKiosk.SerializeState(State);
    Exit;
  end;
  if FLocutus <> nil then
  begin
    FLocutus.SerializeState(State);
    if FJLP <> nil then
      FJLP.SerializeState(State);
    Exit;
  end;
  // Banked writable ranges can address any physical page.
  State.Field(FMemory, SizeOf(FMemory));
  State.Field(FBanks, SizeOf(FBanks));
  if FJLP <> nil then
    if State.Version = 1 then
      FJLP.Reset
    else
      FJLP.SerializeState(State);
  if FPageWindows = [] then
    Exit;
  if State.Version = 1 then
  begin
    ResetPages;
    Exit;
  end;
  State.Field(FPageSelect, SizeOf(FPageSelect));
  for var Window := Low(FPageSelect) to High(FPageSelect) do
  begin
    if FPageSelect[Window] > 15 then
      raise EReadError.Create('Invalid Intellivision cartridge page selection');
    if Window in FPageWindows then
      for var Page := 0 to 15 do
        if FPages[Window, Page].Memory <> nil then
          State.Field(FPages[Window, Page].Memory[0], $1000 * SizeOf(Word));
  end;
end;

end.

