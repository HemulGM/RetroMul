unit RetroTune.Decoder.DSF;

interface

implementation

uses
  System.SysUtils, System.Classes, System.ZLib, System.Math, System.IOUtils,
  System.Generics.Collections, RetroTune.Decoder, RetroTune.Binary,
  DC.AudioMachine;

type
  TDSFDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FMachine: TDSFAudio;
    FInfo: TTuneInfo;
    FPosition, FLimit, FFade: Int64;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function CRC32(const Data: TBytes; Offset, Count: Integer): Cardinal;
begin
  RequireBytes(Data, Offset, Count);
  Result := $FFFFFFFF;
  for var I := Offset to Offset + Count - 1 do
  begin
    Result := Result xor Data[I];
    for var Bit := 0 to 7 do
      if Result and 1 <> 0 then
        Result := (Result shr 1) xor $EDB88320
      else
        Result := Result shr 1;
  end;
  Result := Result xor $FFFFFFFF;
end;

function Seconds(const S: string): Double;
begin
  Result := 0;
  var Parts := S.Split([':']);
  if Length(Parts) > 3 then
    raise EArgumentException.Create('Invalid PSF duration');
  for var P in Parts do
  begin
    var N: Double;
    if not TryStrToFloat(P, N, TFormatSettings.Invariant) or IsNan(N) or IsInfinite(N) or (N < 0) then
      raise EArgumentException.Create('Invalid PSF duration');
    Result := Result * 60 + N;
  end;
  if Result > 86400 then
    raise EArgumentException.Create('PSF duration exceeds one day');
end;

function ReadPSF(const Data: TBytes; out Tags: string): TBytes;
begin
  RequireBytes(Data, 0, 16);
  if (TEncoding.ASCII.GetString(Data, 0, 3) <> 'PSF') or (Data[3] <> $12) then
    raise EArgumentException.Create('Invalid DSF header');
  var Reserved := LE32(Data, 4);
  var PackedSize := LE32(Data, 8);
  if (Reserved > Cardinal(Length(Data) - 16)) or (PackedSize > Cardinal(Length(Data) - 16) - Reserved) then
    raise EArgumentException.Create('Truncated DSF sections');
  var Offset := 16 + Integer(Reserved);
  if CRC32(Data, Offset, Integer(PackedSize)) <> LE32(Data, 12) then
    raise EArgumentException.Create('Invalid DSF checksum');
  var Stream := TBytesStream.Create(Copy(Data, Offset, Integer(PackedSize)));
  try
    var Z := TZDecompressionStream.Create(Stream);
    try
      var Output := TMemoryStream.Create;
      try
        var Buffer: array[0..8191] of Byte;
        while True do
        begin
          var Count := Z.Read(Buffer, Length(Buffer));
          if Count = 0 then
            Break;
          if Output.Size > $800004 - Count then
            raise EArgumentException.Create('DSF program exceeds 8 MiB');
          Output.WriteBuffer(Buffer, Count);
        end;
        SetLength(Result, Output.Size);
        Output.Position := 0;
        if Length(Result) > 0 then
          Output.ReadBuffer(Result[0], Length(Result));
      finally
        Output.Free;
      end;
    finally
      Z.Free;
    end;
  finally
    Stream.Free;
  end;
  RequireBytes(Result, 0, 4);
  var Address := LE32(Result, 0);
  var Size := Length(Result) - 4;
  if (Address > $800000) or (Cardinal(Size) > $800000 - Address) then
    raise EArgumentException.Create('DSF program address');
  Offset := Offset + Integer(PackedSize);
  Tags := '';
  if Offset < Length(Data) then
  begin
    RequireBytes(Data, Offset, 5);
    if TEncoding.ASCII.GetString(Data, Offset, 5) <> '[TAG]' then
      raise EArgumentException.Create('Invalid DSF tag header');
    Tags := TEncoding.UTF8.GetString(Data, Offset + 5, Length(Data) - Offset - 5);
  end;
end;

function ResolveDSF(const Path: string; const Data: TBytes): TBytes;
var
  Active: TList<string>;
  Image: TBytes;
  Highest, Files: Integer;
  RootTags: string;

  function LibraryIndex(const Key: string): Integer;
  begin
    Result := 0;
    if Key = '_lib' then
      Exit(1);
    if Key.StartsWith('_lib') and not TryStrToInt(Key.Substring(4), Result) then
      raise EArgumentException.Create('Invalid DSF library tag');
    if Key.StartsWith('_lib') and ((Result < 2) or (Result > 32)) then
      raise EArgumentException.Create('DSF library index must be 2..32');
  end;

  procedure Load(const Name: string; const Bytes: TBytes; Depth: Integer);
  var
    Libs: array[1..32] of string;
  begin
    if (Depth >= 16) or (Files >= 128) then
      raise EArgumentException.Create('DSF library limit');
    var Full := TPath.GetFullPath(Name);
    for var S in Active do
      if SameText(S, Full) then
        raise EArgumentException.Create('Cyclic DSF libraries');
    Active.Add(Full);
    Inc(Files);
    try
      var Tags: string;
      var ProgramData := ReadPSF(Bytes, Tags);
      if Depth = 0 then
        RootTags := Tags;
      for var Line in Tags.Split([#10]) do
      begin
        var Eq := Line.IndexOf('=');
        if Eq < 1 then
          Continue;
        var N := LibraryIndex(LowerCase(Line.Substring(0, Eq).Trim));
        if N > 0 then
          Libs[N] := Line.Substring(Eq + 1).Trim;
      end;
      for var N := 1 to 32 do
      begin
        if N = 2 then
        begin
          var Address := Integer(LE32(ProgramData, 0));
          var Size := Length(ProgramData) - 4;
          Highest := Max(Highest, Address + Size);
          for var I := 0 to Size - 1 do
            Image[Address + I] := ProgramData[4 + I];
        end;
        if Libs[N] = '' then
          Continue;
        var LibPath := TPath.GetFullPath(TPath.Combine(ExtractFilePath(Full), Libs[N]));
        var Input := TFileStream.Create(LibPath, fmOpenRead or fmShareDenyWrite);
        var LibData: TBytes;
        try
          if Input.Size > 16 * 1024 * 1024 then
            raise EArgumentException.Create('DSF library exceeds 16 MiB');
          SetLength(LibData, Input.Size);
          if Length(LibData) > 0 then
            Input.ReadBuffer(LibData[0], Length(LibData));
        finally
          Input.Free;
        end;
        Load(LibPath, LibData, Depth + 1);
      end;
    finally
      Active.Delete(Active.Count - 1);
    end;
  end;

begin
  Active := TList<string>.Create;
  Highest := 0;
  Files := 0;
  SetLength(Image, $800000);
  try
    Load(Path, Data, 0);
  finally
    Active.Free;
  end;
 // Preserve an immutable, self-contained image for playback, reset and WAV export.
  var ProgramData: TBytes;
  SetLength(ProgramData, Highest + 4);
  for var I := 0 to Highest - 1 do
    ProgramData[4 + I] := Image[I];
  var Output := TMemoryStream.Create;
  var Compressed: TBytes;
  try
    var Z := TZCompressionStream.Create(Output);
    try
      Z.WriteBuffer(ProgramData[0], Length(ProgramData));
    finally
      Z.Free;
    end;
    SetLength(Compressed, Output.Size);
    Output.Position := 0;
    Output.ReadBuffer(Compressed[0], Length(Compressed));
  finally
    Output.Free;
  end;
  var Tags := '[TAG]';
  for var Line in RootTags.Split([#10]) do
  begin
    var Eq := Line.IndexOf('=');
    if Eq < 1 then
      Continue;
    if LibraryIndex(LowerCase(Line.Substring(0, Eq).Trim)) = 0 then
      Tags := Tags + Line + #10;
  end;
  var TagBytes := TEncoding.UTF8.GetBytes(Tags);
  SetLength(Result, 16 + Length(Compressed) + Length(TagBytes));
  Result[0] := Ord('P');
  Result[1] := Ord('S');
  Result[2] := Ord('F');
  Result[3] := $12;
  var Sum := CRC32(Compressed, 0, Length(Compressed));
  for var I := 0 to 3 do
  begin
    Result[8 + I] := (Length(Compressed) shr (I * 8)) and 255;
    Result[12 + I] := (Sum shr (I * 8)) and 255;
  end;
  for var I := 0 to High(Compressed) do
    Result[16 + I] := Compressed[I];
  for var I := 0 to High(TagBytes) do
    Result[16 + Length(Compressed) + I] := TagBytes[I];
end;

constructor TDSFDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  var Tags: string;
  var Image := ReadPSF(Data, Tags);
  var Address := Integer(LE32(Image, 0));
  var Size := Length(Image) - 4;
  var ProgramImage: TBytes;
  SetLength(ProgramImage, Address + Size);
  for var I := 0 to Size - 1 do
    ProgramImage[Address + I] := Image[4 + I];
  FInfo.FormatName := 'DSF';
  FInfo.Details := 'Dreamcast / ARM7DI / AICA';
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.TrackDurations := [-1];
  FLimit := -1;
  FFade := 0;
  if Tags <> '' then
  begin
    var Duration: Double := -1;
    var Fade := 0.0;
    for var Line in Tags.Split([#10]) do
    begin
      var Eq := Line.IndexOf('=');
      if Eq < 1 then
        Continue;
      var Key := LowerCase(Line.Substring(0, Eq).Trim);
      var Value := Line.Substring(Eq + 1).Trim;
      if Key.StartsWith('_lib') then
        raise EArgumentException.Create('DSF library needs file context');
      if Key = 'title' then
        FInfo.Title := Value
      else if Key = 'artist' then
        FInfo.Artist := Value
      else if Key = 'copyright' then
        FInfo.CopyrightText := Value
      else if Key = 'length' then
        Duration := Seconds(Value)
      else if Key = 'fade' then
        Fade := Seconds(Value);
      var N := Length(FInfo.Metadata);
      SetLength(FInfo.Metadata, N + 1);
      FInfo.Metadata[N].Name := Key;
      FInfo.Metadata[N].Value := Value;
    end;
    if Duration >= 0 then
    begin
      FLimit := Round((Duration + Fade) * 44100);
      FFade := Round(Fade * 44100);
      FInfo.TrackDurations := [(Duration + Fade)];
    end;
  end;
  FMachine := TDSFAudio.Create(ProgramImage);
end;

destructor TDSFDecoder.Destroy;
begin
  FMachine.Free;
  inherited;
end;

function TDSFDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TDSFDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('DSF track');
  FMachine.Reset;
  FPosition := 0;
end;

function TDSFDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while (Result < Frames) and ((FLimit < 0) or (FPosition < FLimit)) do
  begin
    var L, R: SmallInt;
    FMachine.Sample(L, R);
    var Gain := 1.0;
    if (FLimit >= 0) and (FFade > 0) and (FPosition > FLimit - FFade) then
      Gain := (FLimit - FPosition) / FFade;
    Samples[Result * 2] := Round(L * Gain);
    Samples[Result * 2 + 1] := Round(R * Gain);
    Inc(Result);
    Inc(FPosition);
  end;
end;

function OpenDSF(const Data: TBytes): ITuneDecoder;
begin
  Result := TDSFDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.dsf', 'Dreamcast Sound Format', OpenDSF);
  TTuneDecoders.RegisterFormat('.minidsf', 'Dreamcast Sound Format (shared libraries)', OpenDSF);
  TTuneDecoders.RegisterDataLoader('.dsf', ResolveDSF);
  TTuneDecoders.RegisterDataLoader('.minidsf', ResolveDSF);

end.

