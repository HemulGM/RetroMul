unit GW.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, GW.CPU, GW.Catalog,
  GW.MGW.Package, GW.Artwork, Core.Emulation.Types, Core.Archive.Container;

type
  TGWLayer = GW.Artwork.TGWLayer;

  TGWArtwork = GW.Artwork.TGWArtwork;

  TGWCartridge = class
  private
    FRenderer: IGWArtworkRenderer;
    procedure Initialize(const Renderer: IGWArtworkRenderer);
    procedure LoadGW(const Bytes: TBytes);
    procedure LoadMAME(const Container: IArchiveContainer; const Name: string);
  public
    MGW: TMGWPackage;
    Model: TGWCPUModel;
    RMask, SoundMode, DecayPivot, DecayLength, FixedRow: Integer;
    GWInputFallback: Boolean;
    ProgramData, MelodyData, IdentityData, SnapshotHash: TBytes;
    Keys: TGWKeyMatrix;
    BA, B: Cardinal;
    Title: string;
    Artwork: TGWArtwork;
    destructor Destroy; override;
    constructor Create(const Bytes: TBytes; const Name: string; const Renderer: IGWArtworkRenderer = nil; const Container: IArchiveContainer = nil); overload;
    constructor Create(const Container: IArchiveContainer; const Name: string; const Renderer: IGWArtworkRenderer = nil); overload;
    function SupportedButtons: TEmulatorButtons;
    class function Recognizes(const Container: IArchiveContainer; const Name: string): Boolean; overload; static;
    class function Recognizes(const Bytes: TBytes; const Name: string): Boolean; overload; static;
    class function Recognizes(Stream: TStream; const Name: string): Boolean; overload; static;
  end;

function GWColor565(Value: Word): TAlphaColor;

implementation

uses
  Core.MediaArchive, System.Hash, System.ZLib, System.Math, CHD.LZMA;

const
  MaxData = 8 * 1024 * 1024;

procedure Require(Value: Boolean; const Message: string);
begin
  if not Value then
    raise EReadError.Create('Game & Watch: ' + Message);
end;

function LE(const Data: TBytes; Offset, Size: Integer): Cardinal;
begin
  Require((Offset >= 0) and (Offset <= Length(Data) - Size), 'truncated data');
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := Result or (Cardinal(Data[Offset + i]) shl (i * 8));
end;

function Magic(const Data: TBytes; const Text: AnsiString): Boolean;
begin
  Result := Length(Data) >= Length(Text);
  if Result then
    for var i := 1 to Length(Text) do
      if Data[i - 1] <> Ord(Text[i]) then
        Exit(False);
end;

function TGWCartridge.SupportedButtons: TEmulatorButtons;
begin
  Result := [];
  if MGW <> nil then
    Exit; // Runtime keymap is published by the script worker.
  var Mask := BA or B;
  for var Row := Low(Keys) to High(Keys) do
    for var Bit := Low(Keys[Row]) to High(Keys[Row]) do
      Mask := Mask or Keys[Row, Bit];
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if (Mask and (Cardinal(1) shl Ord(Button))) <> 0 then
      Include(Result, Button);
end;

function GWColor565(Value: Word): TAlphaColor;
begin
  var R := (Value shr 11) and 31;
  var G := (Value shr 5) and 63;
  var B := Value and 31;
  Result := $FF000000 or (Cardinal((R shl 3) or (R shr 2)) shl 16) or
    (Cardinal((G shl 2) or (G shr 4)) shl 8) or Cardinal((B shl 3) or (B shr 2));
end;

function Inflate(const Data: TBytes): TBytes;
begin
  var Input := TBytesStream.Create(Data);
  var Output := TMemoryStream.Create;
  var Decoder: TDecompressionStream := nil;
  try
    Decoder := TDecompressionStream.Create(Input, -15);
    var Buffer: array[0..4095] of Byte;
    repeat
      var Count := Decoder.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then
        Break;

      Require(Output.Size + Count <= MaxData, 'compressed package exceeds 8 MiB');
      Output.WriteBuffer(Buffer, Count);
    until False;
    SetLength(Result, Output.Size);
    if Length(Result) > 0 then
      Move(Output.Memory^, Result[0], Length(Result));
  finally
    Decoder.Free;
    Output.Free;
    Input.Free;
  end;
end;

function DecodeLZ4(const Data: TBytes; out Consumed: Integer): TBytes;
var
  P, N, BlockEnd, Token, Count, Distance, Base: Integer;

  procedure Grow(Extra: Integer);
  begin
    Require((Extra >= 0) and (N <= MaxData - Extra), 'LZ4 output too large');
    SetLength(Result, N + Extra);
  end;

  function ExtraLength(Value: Integer): Integer;
  begin
    Result := Value;
    if Value = 15 then
      repeat
        Require(P < BlockEnd, 'truncated LZ4 length');
        Value := Data[P];
        Inc(P);
        Inc(Result, Value);
      until Value <> 255;
  end;

begin
  Require(LE(Data, 0, 4) = $184D2204, 'invalid LZ4 frame');
  Require(Length(Data) >= 7, 'truncated LZ4 header');
  var Flags := Data[4];
  Require((Flags and $C0) = $40, 'unsupported LZ4 version');
  P := 6;
  N := 0;
  if (Flags and 8) <> 0 then
    Inc(P, 8);
  if (Flags and 1) <> 0 then
    Inc(P, 4);
  Inc(P); // header checksum
  repeat
    var Block := LE(Data, P, 4);
    Inc(P, 4);
    if Block = 0 then
      Break;

    Count := Block and $7FFFFFFF;
    Require(Count <= Length(Data) - P, 'truncated LZ4 block');
    BlockEnd := P + Count;
    Base := N;
    if (Block and $80000000) <> 0 then
    begin
      Grow(Count);
      Move(Data[P], Result[N], Count);
      Inc(N, Count);
      P := BlockEnd;
    end
    else
      while P < BlockEnd do
      begin
        Token := Data[P];
        Inc(P);
        Count := ExtraLength(Token shr 4);
        Require(Count <= BlockEnd - P, 'truncated LZ4 literals');
        Grow(Count);
        if Count > 0 then
          Move(Data[P], Result[N], Count);
        Inc(P, Count);
        Inc(N, Count);
        if P = BlockEnd then
          Break;

        Require(P + 2 <= BlockEnd, 'truncated LZ4 match');
        Distance := LE(Data, P, 2);
        Inc(P, 2);
        Require((Distance > 0) and (Distance <= N), 'invalid LZ4 distance');
        if (Flags and 32) <> 0 then
          Require(Distance <= N - Base, 'invalid independent LZ4 block');
        Count := ExtraLength(Token and 15) + 4;
        Grow(Count);
        for var i := 1 to Count do
        begin
          Result[N] := Result[N - Distance];
          Inc(N);
        end;
      end;
    if (Flags and 16) <> 0 then
      Inc(P, 4);
  until False;
  if (Flags and 4) <> 0 then
    Inc(P, 4);
  Require(P <= Length(Data), 'truncated LZ4 checksum');
  Consumed := P;
end;

class function TGWCartridge.Recognizes(const Bytes: TBytes; const Name: string): Boolean;
begin
  var Stream := TBytesStream.Create(Bytes);
  try
    Result := Recognizes(Stream, Name);
  finally
    Stream.Free;
  end;
end;

class function TGWCartridge.Recognizes(Stream: TStream; const Name: string): Boolean;
begin
  var Saved := Stream.Position;
  try
    var Prefix: TBytes;
    SetLength(Prefix, 4);
    var Count := 0;
    while Count < Length(Prefix) do
    begin
      var Read := Stream.Read(Prefix[Count], Length(Prefix) - Count);
      if Read = 0 then
        Break;
      if Read < 0 then
        raise EReadError.Create('Invalid stream read count');
      Inc(Count, Read);
    end;
    SetLength(Prefix, Count);
    Result := SameText(ExtractFileExt(Name), '.mgw') or Magic(Prefix, 'BZh') or
      SameText(ExtractFileExt(Name), '.gw') or Magic(Prefix, 'SM5') or
      Magic(Prefix, 'ZLIB') or Magic(Prefix, 'LZMA') or Magic(Prefix, #$04#$22#$4D#$18);
    if not Result and IsMediaArchive(Name) then
    begin
      Stream.Position := Saved;
      Result := Recognizes(OpenMediaArchive(Stream, Name), Name);
    end;
  finally
    Stream.Position := Saved;
  end;
end;

class function TGWCartridge.Recognizes(const Container: IArchiveContainer; const Name: string): Boolean;
begin
  Result := False;
  if Container = nil then
    Exit;
  var Info: TGWModelInfo;
  if FindGWModel(ChangeFileExt(ExtractFileName(Name), ''), Info) then
    Exit(True);
  for var I := 0 to Container.Count - 1 do
  begin
    var Entry := Container.Entries[I];
    if Entry.IsDirectory then
      Continue;
    if SameText(ExtractFileExt(Entry.Name), '.gw') or
      (SameText(ExtractFileExt(Entry.Name), '.svg') and ExtractFileName(Entry.Name).StartsWith('gnw_', True)) then
      Exit(True);
  end;
end;

procedure TGWCartridge.Initialize(const Renderer: IGWArtworkRenderer);
begin
  FRenderer := Renderer;
  if FRenderer = nil then
    FRenderer := DefaultGWArtworkRenderer;
  FixedRow := -1;
  DecayPivot := 8;
  DecayLength := 17;
  SoundMode := 1;
end;

constructor TGWCartridge.Create(const Container: IArchiveContainer; const Name: string; const Renderer: IGWArtworkRenderer);
begin
  inherited Create;
  Require(Container <> nil, 'missing archive container');
  Initialize(Renderer);
  LoadMAME(Container, Name);
  var IdentityHash := THashSHA2.Create;
  IdentityHash.Update(IdentityData);
  SnapshotHash := IdentityHash.HashAsBytes;
end;

constructor TGWCartridge.Create(const Bytes: TBytes; const Name: string; const Renderer: IGWArtworkRenderer; const Container: IArchiveContainer);
begin
  inherited Create;
  Initialize(Renderer);
  Require((Length(Bytes) > 0) and (Length(Bytes) <= MaxData), 'empty or oversized package');
  IdentityData := Copy(Bytes);
  if Magic(Bytes, 'BZh') then
  begin
    MGW := TMGWPackage.Create(Bytes);
    Title := ChangeFileExt(ExtractFileName(Name), '');
  end
  else if Container <> nil then
    LoadMAME(Container, Name)
  else if Magic(Bytes, 'SM5') or Magic(Bytes, 'ZLIB') or Magic(Bytes, 'LZMA') or Magic(Bytes, #$04#$22#$4D#$18) then
    LoadGW(Bytes)
  else if IsMediaArchive(Name) then
  begin
    var Input := TBytesStream.Create(Bytes);
    try
      LoadMAME(OpenMediaArchive(Input, Name), Name);
    finally
      Input.Free;
    end;
  end
  else
    LoadGW(Bytes);
  var IdentityHash := THashSHA2.Create;
  IdentityHash.Update(Bytes);
  SnapshotHash := IdentityHash.HashAsBytes;
end;

destructor TGWCartridge.Destroy;
begin
  MGW.Free;
  inherited;
end;

procedure TGWCartridge.LoadGW(const Bytes: TBytes);
const
  Mapping: array[0..7] of Integer = (2, 0, 3, 1, 4, 5, 6, 7);
var
  Data: TBytes;
  Tail, Size: Integer;

  function Section(N: Integer): TBytes;
  begin
    var Start := LE(Data, 28 + N * 8, 4);
    var Count := LE(Data, 32 + N * 8, 4);
    Require((Start >= 108) and (Start <= Cardinal(Length(Data))) and
      (Count <= Cardinal(Length(Data)) - Start), 'invalid section range');
    Result := Copy(Data, Integer(Start), Integer(Count));
  end;

begin
  GWInputFallback := True;
  Tail := Length(Bytes);
  if Magic(Bytes, 'ZLIB') or Magic(Bytes, 'LZMA') then
  begin
    Size := LE(Bytes, 4, 4);
    Require((Size > 0) and (Size <= Length(Bytes) - 8), 'invalid compressed size');
    Tail := Size + 8;
    if Magic(Bytes, 'ZLIB') then
      Data := Inflate(Copy(Bytes, 8, Size))
    else
    begin
      // CHD's existing native decoder uses the same lc=3/lp=0/pb=2 properties.
      // Decode enough of the header to read the exact output length; no guessed buffer.
      var PackedData := Copy(Bytes, 8, Size);
      var Prefix := CHDLZMA(PackedData, 108, True);
      var Total := UInt64(LE(Prefix, 100, 4)) + LE(Prefix, 104, 4);
      Require((Total >= 108) and (Total <= MaxData), 'invalid LZMA output length');
      Data := CHDLZMA(PackedData, Integer(Total));
    end;
  end
  else if Magic(Bytes, #$04#$22#$4D#$18) then
    Data := DecodeLZ4(Bytes, Tail)
  else
    Data := Copy(Bytes);
  Require(Length(Data) >= 108, 'truncated GW header');
  var CPUName := TEncoding.ASCII.GetString(Data, 0, 8);
  if CPUName.StartsWith('SM5A') then
    Model := TGWCPUModel.SM5A
  else if CPUName.StartsWith('SM5L') then
    Model := TGWCPUModel.SM5L
  else if CPUName.StartsWith('SM500') then
    Model := TGWCPUModel.SM500
  else if CPUName.StartsWith('SM510') then
    Model := TGWCPUModel.SM510
  else if CPUName.StartsWith('SM511') then
    Model := TGWCPUModel.SM511
  else if CPUName.StartsWith('SM512') then
    Model := TGWCPUModel.SM512
  else
    raise EReadError.Create('Unsupported Game & Watch CPU: ' + CPUName.Trim);

  RMask := -1;
  if Model = TGWCPUModel.SM510 then
    RMask := 2;
  Title := TEncoding.ASCII.GetString(Data, 8, 8).Trim;
  var Flags := LE(Data, 24, 4);
  SoundMode := (Flags shr 1) and 7;
  ProgramData := Section(8);
  MelodyData := Section(7);
  Require((Length(ProgramData) > 0) and (Length(ProgramData) <= 4096), 'invalid program size');
  Require((Length(MelodyData) = 0) or (Length(MelodyData) = 256), 'invalid melody size');
  if Model in [TGWCPUModel.SM511, TGWCPUModel.SM512] then
    Require(Length(MelodyData) = 256, 'missing melody ROM');
  var Keyboard := Section(9);
  Require(Length(Keyboard) = 40, 'invalid keyboard matrix');

  for var Row := 0 to 7 do
    for var Bit := 0 to 3 do
    begin
      var Mask: Cardinal := 0;
      var Value := (LE(Keyboard, Row * 4, 4) shr (Bit * 8)) and $FF;
      for var Key := 0 to 7 do
        if (Value and (1 shl Key)) <> 0 then
          Mask := Mask or (Cardinal(1) shl Mapping[Key]);
      Keys[Row, Bit] := Mask;
    end;
  for var Pin := 0 to 1 do
  begin
    var Mask: Cardinal := 0;
    var Value := LE(Keyboard, 32 + Pin * 4, 4);
    for var Key := 0 to 7 do
      if (Value and (1 shl Key)) <> 0 then
        Mask := Mask or (Cardinal(1) shl Mapping[Key]);
    if Pin = 0 then
      BA := Mask
    else
      B := Mask;
  end;
  Artwork.Width := 320;
  Artwork.Height := 240;
  var Background := Section(0);
  SetLength(Artwork.Background, 320 * 240);
  if Length(Background) > 0 then
  begin
    Require(Length(Background) = 320 * 240 * 2, 'invalid RGB565 background');
    for var i := 0 to High(Artwork.Background) do
      Artwork.Background[i] := GWColor565(LE(Background, i * 2, 2));
  end
  else if ((Flags and $20) <> 0) and (Tail < Length(Bytes)) then
  begin
    Require(FRenderer <> nil, 'no bitmap renderer supplied by frontend');
    Artwork.Background := FRenderer.DecodeBitmap(Copy(Bytes, Tail, Length(Bytes) - Tail), 320, 240);
  end
  else
    for var i := 0 to High(Artwork.Background) do
      Artwork.Background[i] := $FFE0E3CE;
  var Pixels := Section(1);
  var Offsets := Section(2);
  var X := Section(3);
  var Y := Section(4);
  var H := Section(5);
  var W := Section(6);
  Require((Length(Offsets) = 1024) and (Length(X) = 512) and (Length(Y) = 512) and
    (Length(H) = 512) and (Length(W) = 512), 'invalid segment table');
  var Bits := 8;
  if (Flags and $10) <> 0 then
    Bits := 4;
  if (Flags and $100) <> 0 then
    Bits := 2;
  var Inverted := (Flags and 1) <> 0;
  for var Index := 0 to 255 do
  begin
    var Layer: TGWLayer;
    Layer.Index := Index;
    Layer.X := LE(X, Index * 2, 2);
    Layer.Y := LE(Y, Index * 2, 2);
    Layer.Width := LE(W, Index * 2, 2);
    Layer.Height := LE(H, Index * 2, 2);
    if (Layer.Width = 0) or (Layer.Height = 0) then
      Continue;

    Require((Layer.X + Layer.Width <= 320) and (Layer.Y + Layer.Height <= 240), 'segment outside screen');
    var Start := UInt64(LE(Offsets, Index * 4, 4));
    var Count := Layer.Width * Layer.Height;
    Require((Start + Cardinal(Count)) * Cardinal(Bits) <= UInt64(Length(Pixels)) * 8, 'truncated segment pixels');
    SetLength(Layer.Pixels, Count);
    for var i := 0 to Count - 1 do
    begin
      var P := Integer(Start) + i;
      var Value: Integer;
      case Bits of
        2:
          Value := ((Pixels[P div 4] shr ((P mod 4) * 2)) and 3) * 85;
        4:
          Value := ((Pixels[P div 2] shr ((1 - (P mod 2)) * 4)) and 15) * 17;
      else
        Value := Pixels[P];
      end;
      if Inverted then
      begin
        var Color := Artwork.Background[(Layer.Y + i div Layer.Width) * 320 + Layer.X + i mod Layer.Width];
        Layer.Pixels[i] := (Cardinal(Value) shl 24) or (((Color shr 16 and 255) * Cardinal(Value) div 255) shl 16) or
          (((Color shr 8 and 255) * Cardinal(Value) div 255) shl 8) or ((Color and 255) * Cardinal(Value) div 255);
      end
      else
        Layer.Pixels[i] := Cardinal(255 - Value) shl 24;
    end;
    Artwork.Layers := Artwork.Layers + [Layer];
  end;
  if Inverted then
    for var i := 0 to High(Artwork.Background) do
      Artwork.Background[i] := $FF000000;
  Require(Length(Artwork.Layers) > 0, 'package contains no LCD segments');
end;

procedure TGWCartridge.LoadMAME(const Container: IArchiveContainer; const Name: string);
begin
  var Archive := Container;
  try
    var Embedded := -1;
    for var i := 0 to Archive.Count - 1 do
      if not Archive.Entries[i].IsDirectory and SameText(ExtractFileExt(Archive.Entries[i].Name), '.gw') then
      begin
        Require(Embedded < 0, 'archive contains multiple GW packages');
        Embedded := i;
      end;

    if Embedded >= 0 then
    begin
      Require(Archive.Entries[Embedded].Size <= MaxData, 'oversized GW entry');
      var Data: TBytes;
      Archive.Read(Embedded, Data);
      IdentityData := Copy(Data);
      LoadGW(Data);
      Exit;
    end;

    var Info: TGWModelInfo;
    var Id := ChangeFileExt(ExtractFileName(Name), '');
    if not FindGWModel(Id, Info) then
    begin
      var Found := False;
      for var Candidate in GWModels do
        for var FileName in Archive.Names do
          if SameText(ExtractFileName(FileName), Candidate.Screens.Split([';'])[0]) then
          begin
            Require(not Found, 'ambiguous MAME model');
            Info := Candidate;
            Found := True;
          end;
      Require(Found, 'unknown MAME Game & Watch model');
    end;
    var ReadEntry: TFunc<string, Integer, TBytes> :=
      function(Entry: string; Limit: Integer): TBytes
      begin
        var Match := -1;
        for var i := 0 to Archive.Count - 1 do
          if not Archive.Entries[i].IsDirectory and SameText(ExtractFileName(Archive.Entries[i].Name), Entry) then
          begin
            Require(Match < 0, 'duplicate archive entry ' + Entry);
            Match := i;
          end;
        Require(Match >= 0, 'missing ' + Entry + ' in MAME archive');
        Require(Archive.Entries[Match].Size <= Cardinal(Limit), 'oversized ' + Entry);
        Archive.Read(Match, Result);
      end;
    Model := Info.CPU;
    Title := Info.Title;
    RMask := Info.RMask;
    FixedRow := Info.FixedRow;
    SoundMode := Info.SoundMode;
    Keys := Info.Keys;
    BA := Info.BA;
    B := Info.B;
    ProgramData := ReadEntry(Info.ProgramFile, 4096);
    Require(Length(ProgramData) = Info.ProgramSize, 'incorrect program size');
    if Info.MelodyFile <> '' then
    begin
      MelodyData := ReadEntry(Info.MelodyFile, 256);
      Require(Length(MelodyData) = 256, 'incorrect melody size');
    end;
    var Screens: TArray<string> := nil;
    for var Entry in Info.Screens.Split([';']) do
      Screens := Screens + [TEncoding.UTF8.GetString(ReadEntry(Entry, 4 * 1024 * 1024))];
    var Hash := THashSHA2.Create;
    Hash.Update(TEncoding.UTF8.GetBytes('GW:MAME:' + Info.Id));
    Hash.Update(ProgramData);
    Hash.Update(MelodyData);
    for var Screen in Screens do
      Hash.Update(TEncoding.UTF8.GetBytes(Screen));
    IdentityData := Hash.HashAsBytes;
    Require(FRenderer <> nil, 'no SVG renderer supplied by frontend');
    Artwork := FRenderer.Render(Screens, Info.Layout, Model in [TGWCPUModel.SM5A, TGWCPUModel.SM5L, TGWCPUModel.SM500]);
    if Info.Id = 'gnw_tbridge' then
    begin
      DecayPivot := 25;
      DecayLength := 25;
    end;
  finally
    Archive := nil;
  end;
end;

end.

