unit SWF.Movie;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, SWF.Reader,
  SWF.Geometry, Media.Image.PixelBuffer, SWF.Sound, SWF.Video;

const
  SWFClipLoad = $00001;
  SWFClipEnterFrame = $00002;
  SWFClipUnload = $00004;
  SWFClipMouseMove = $00008;
  SWFClipMouseDown = $00010;
  SWFClipMouseUp = $00020;
  SWFClipKeyDown = $00040;
  SWFClipKeyUp = $00080;
  SWFClipData = $00100;
  SWFClipInitialize = $00200;
  SWFClipPress = $00400;
  SWFClipRelease = $00800;
  SWFClipReleaseOutside = $01000;
  SWFClipRollOver = $02000;
  SWFClipRollOut = $04000;
  SWFClipDragOver = $08000;
  SWFClipDragOut = $10000;
  SWFClipKeyPress = $20000;
  SWFClipConstruct = $40000;

type
  TSWFClipAction = record
    Events: Cardinal;
    KeyCode: Byte;
    Code: TBytes;
  end;

  TSWFPoint = record
    X, Y: Double;
  end;

  TSWFEdge = record
    X1, Y1, X2, Y2: Double;
    Fill: Integer;
  end;

  TSWFGradientKind = (sgNone, sgLinear, sgRadial, sgFocal);

  TSWFGradientSpread = (gsPad, gsReflect, gsRepeat);

  TSWFGradientStop = SWF.Reader.TSWFGradientStop;

  TSWFGradient = record
    Kind: TSWFGradientKind;
    Spread: TSWFGradientSpread;
    LinearRGB: Boolean;
    Matrix: TSWFMatrix;
    Focal: Double;
    Stops: TArray<TSWFGradientStop>;
  end;

  TSWFLineCap = (lcRound, lcNone, lcSquare);

  TSWFLineJoin = (ljRound, ljBevel, ljMiter);

  TSWFStroke = record
    Width: Integer;
    StartCap, EndCap: TSWFLineCap;
    Join: TSWFLineJoin;
    MiterLimit: Double;
    NoHScale, NoVScale, NoClose: Boolean;
  end;

  TSWFStrokePath = record
    Fill: Integer;
    Points: TArray<TSWFPoint>;
  end;

  TSWFFill = record
    Color: Cardinal;
    BitmapId: Integer;
    BitmapData: IImagePixelBuffer;
    BitmapMatrix: TSWFMatrix;
    BitmapRepeat, BitmapSmooth, Stroke: Boolean;
    Gradient: TSWFGradient;
    Line: TSWFStroke;
  end;

  TSWFTag = record
    Code, Ordinal: Integer;
    Data: TBytes;
  end;

  TSWFFrame = record
    Tags: TArray<TSWFTag>;
    StreamSound: TSWFSound; // Owned by the movie, shared by instances of this timeline.
    StreamOffset, StreamEnd: Integer; // Sample frames, with an exclusive end.
  end;

  TSWFScene = record
    Name: string;
    StartFrame: Integer; // Zero-based offset in the root timeline.
  end;

  TSWFButtonRecord = record
    States, CharacterId, Depth: Integer;
    Matrix: TSWFMatrix;
    ColorTransform: TSWFColorTransform;
    BlendMode: Byte;
    Filters: TSWFFilters;
  end;

  TSWFButtonAction = record
    Conditions: Word;
    Code: TBytes;
  end;

  TSWFButtonSounds = array[0..3] of TSWFSoundEvent;

  TSWFGlyphEntry = record
    Index, Advance: Integer;
  end;

  TSWFTextRecord = record
    FontId, Height, X, Y: Integer;
    Color: Cardinal;
    Glyphs: TArray<TSWFGlyphEntry>;
  end;

  TSWFShapeSegment = record
    X1, Y1, CX, CY, X2, Y2: Integer;
    Curved: Boolean;
  end;

  TSWFMorphSegment = record
    First, Last: TSWFShapeSegment;
    Fill0, Fill1, Stroke: Integer;
    BreakStroke: Boolean;
  end;

  TSWFMorph = class;

  TSWFCharacter = class
  private
    FMorph: TSWFMorph;
  public
    Id, Kind: Integer;
    Bounds: TSWFRect;
    ShapeBounds, PathBounds: TSWFBounds;
    Fills: TArray<TSWFFill>;
    Edges: TArray<TSWFEdge>;
    StrokePaths: TArray<TSWFStrokePath>;
    EvenOddFills: Boolean;
    Frames: TArray<TSWFFrame>;
    Data: TBytes;
    Buttons: TArray<TSWFButtonRecord>;
    ButtonActions: TArray<TSWFButtonAction>;
    TrackAsMenu: Boolean;
    Glyphs: TObjectList<TSWFCharacter>;
    FontCodes, FontAdvances: TArray<Integer>;
    FontName: string;
    FontAscent, FontDescent, FontLeading: Integer;
    TextMatrix: TSWFMatrix;
    TextRecords: TArray<TSWFTextRecord>;
    BitmapWidth, BitmapHeight: Integer;
    BitmapPixels: TArray<Cardinal>; // Straight ARGB, in top-to-bottom row order.
    Video: TSWFVideoStream;
    constructor Create;
    destructor Destroy; override;
    // A morph definition keeps one interpolated frame. Consume the result
    // before requesting another ratio from the same definition.
    function ShapeAt(Ratio: Word): TSWFCharacter;
  end;

  TSWFMorph = class
  private
    EndBounds, EndPathBounds: TSWFBounds;
    EndFills: TArray<TSWFFill>;
    Segments: TArray<TSWFMorphSegment>;
    Frame: TSWFCharacter;
    FrameRatio: Word;
  public
    destructor Destroy; override;
  end;

  TSWFMovie = class
  private
    FTagCount: Integer;
    FJPEGTables: TBytes;
    FBitmapPixels: Integer;
    FSoundSamples: Integer;
    FStreamSounds: TObjectList<TSWFSound>;
    procedure ParseTimeline(R: TSWFReader; Count, Nesting: Integer; out Frames: TArray<TSWFFrame>);
    procedure DecodeTimelineSound(var Frames: TArray<TSWFFrame>);
    procedure ParseSceneData(R: TSWFReader; FrameCount: Integer);
    procedure ParseShape(C: TSWFCharacter; R: TSWFReader; Version: Integer);
    procedure ParseMorphShape(C: TSWFCharacter; R: TSWFReader);
    procedure ParseButton(C: TSWFCharacter; R: TSWFReader);
    procedure ParseFont(C: TSWFCharacter; R: TSWFReader);
    procedure ParseText(C: TSWFCharacter; R: TSWFReader);
    procedure ParseBitmap(C: TSWFCharacter; R: TSWFReader);
    procedure ParseVideo(C: TSWFCharacter; R: TSWFReader);
    procedure ParseSound(Id: Word; R: TSWFReader);
    function GetBitmapMemorySize: Integer;
  public
    Version, Width, Height, DecodedSize: Integer;
    Stage: TSWFRect;
    FPS: Double;
    Background: Cardinal;
    Frames: TArray<TSWFFrame>;
    InitActions: TArray<TBytes>;
    UsesAVM2: Boolean;
    DocumentClass: string;
    Characters: TObjectDictionary<Integer, TSWFCharacter>;
    Sounds: TObjectDictionary<Integer, TSWFSound>;
    ButtonSounds: TDictionary<Integer, TSWFButtonSounds>;
    ExportNames: TDictionary<string, Integer>;
    SymbolNames: TDictionary<Integer, string>;
    AVM2SymbolNames: TDictionary<Integer, string>;
    AVM2ExportNames: TDictionary<string, Integer>;
    SceneLabels: TArray<TSWFScene>;
    SceneFrameLabels: TDictionary<string, Integer>;
    Warnings: TStringList;
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Warn(const Text: string);
    property BitmapMemorySize: Integer read GetBitmapMemorySize;
    function SoundMemorySize: Integer;
  end;

function SWFColor(R: TSWFReader; Alpha: Boolean): Cardinal;

implementation

uses
  System.Math, AVM1.Names, Media.Image.Types, SWF.Bitmap;

constructor TSWFCharacter.Create;
begin
  inherited;
  Glyphs := TObjectList<TSWFCharacter>.Create;
  ShapeBounds := TSWFBounds.Empty;
  PathBounds := TSWFBounds.Empty;
end;

destructor TSWFCharacter.Destroy;
begin
  Video.Free;
  FMorph.Free;
  Glyphs.Free;
  inherited;
end;

destructor TSWFMorph.Destroy;
begin
  Frame.Free;
  inherited;
end;

procedure TSWFMovie.ParseButton(C: TSWFCharacter; R: TSWFReader);
var
  Flags, Offset, Start, Size: Integer;
  B: TSWFButtonRecord;
  A: TSWFButtonAction;
begin
  Offset := 0;
  if C.Kind = 34 then
  begin
    C.TrackAsMenu := (R.U8 and 1) <> 0;
    Offset := R.U16;
  end;
  while True do
  begin
    Flags := R.U8;
    if Flags = 0 then
      Break;
    B.States := Flags and 15;
    B.CharacterId := R.U16;
    B.Depth := R.U16;
    B.Matrix := R.Matrix;
    B.ColorTransform := TSWFColorTransform.Identity;
    if C.Kind = 34 then
      B.ColorTransform := R.ColorTransform(True);
    B.BlendMode := 0;
    B.Filters := nil;
    if (C.Kind = 34) and ((Flags and $10) <> 0) then
      B.Filters := R.FilterList;
    if (C.Kind = 34) and ((Flags and $20) <> 0) then
      B.BlendMode := R.U8;
    C.Buttons := C.Buttons + [B];
  end;
  if C.Kind = 7 then
  begin
    A.Conditions := 8;
    A.Code := R.Bytes(R.Remaining);
    C.ButtonActions := C.ButtonActions + [A];
  end
  else if Offset <> 0 then
  begin
    if R.Position <> 3 + Offset then
      raise ESWFError.Create('Invalid SWF button action offset');
    while R.Remaining > 0 do
    begin
      Start := R.Position;
      Size := R.U16;
      A.Conditions := R.U16;
      if Size = 0 then
        A.Code := R.Bytes(R.Remaining)
      else
      begin
        if Size < 4 then
          raise ESWFError.Create('Invalid SWF button action size');
        A.Code := R.Bytes(Size - 4);
      end;
      C.ButtonActions := C.ButtonActions + [A];
      if Size = 0 then
        Break;
      if R.Position <> Start + Size then
        raise ESWFError.Create('Invalid button action boundary');
    end;
  end;
end;

procedure TSWFMovie.ParseFont(C: TSWFCharacter; R: TSWFReader);
var
  Flags, Count, Base, EndOffset, NameLength: Integer;
  Offsets: TArray<Integer>;
  WideOffsets, WideCodes: Boolean;
begin
  Flags := 0;
  WideCodes := False;
  if C.Kind = 10 then
  begin
    var First := R.U16;
    if (First and 1) <> 0 then
      raise ESWFError.Create('Invalid font offset table');
    Count := First div 2;
    Base := 0;
    SetLength(Offsets, Count + 1);
    if Count > 0 then
      Offsets[0] := First;
    for var I := 1 to Count - 1 do
      Offsets[I] := R.U16;
    EndOffset := Length(C.Data);
    Offsets[Count] := EndOffset;
  end
  else
  begin
    Flags := R.U8;
    R.U8;
    NameLength := R.U8;
    C.FontName := R.TextBytes(NameLength);
    while C.FontName.EndsWith(#0) do
      Delete(C.FontName, Length(C.FontName), 1);
    Count := R.U16;
    WideOffsets := (Flags and 8) <> 0;
    WideCodes := (Flags and 4) <> 0;
    // Authors can omit the code table offset for a device font without glyphs.
    if (Count = 0) and (R.Remaining = 0) then
      Exit;
    Base := R.Position - 2;
    SetLength(Offsets, Count + 1);
    for var I := 0 to Count do
    begin
      var V: Cardinal;
      if WideOffsets then
        V := R.U32
      else
        V := R.U16;
      if V > Cardinal(Length(C.Data)) then
        raise ESWFError.Create('Invalid font glyph offset');
      Offsets[I] := Integer(V);
    end;
  end;
  for var I := 0 to Count - 1 do
  begin
    var At := Base + Offsets[I];
    var Finish := Base + Offsets[I + 1];
    if (At < 0) or (Finish < At) or (Finish > Length(C.Data)) then
      raise ESWFError.Create('Invalid font glyph range');
    var Glyph := TSWFCharacter.Create;
    C.Glyphs.Add(Glyph);
    var GR := TSWFReader.Create(Copy(C.Data, At, Finish - At), Version);
    try
      ParseShape(Glyph, GR, 0);
    finally
      GR.Free;
    end;
  end;
  if C.Kind <> 10 then
  begin
    var CodeAt := Base + Offsets[Count];
    var CR := TSWFReader.Create(Copy(C.Data, CodeAt, Length(C.Data) - CodeAt), Version);
    try
      SetLength(C.FontCodes, Count);
      SetLength(C.FontAdvances, Count);
      for var I := 0 to Count - 1 do
        if WideCodes then
          C.FontCodes[I] := CR.U16
        else
          C.FontCodes[I] := CR.U8;
      if (Flags and $80) <> 0 then
      begin
        C.FontAscent := CR.S16;
        C.FontDescent := CR.S16;
        C.FontLeading := CR.S16;
        for var I := 0 to Count - 1 do
          C.FontAdvances[I] := CR.S16;
        for var I := 0 to Count - 1 do
          CR.Rect;
        var Kerning := CR.U16;
        for var I := 1 to Kerning do
        begin
          if WideCodes then
          begin
            CR.U16;
            CR.U16;
          end
          else
          begin
            CR.U8;
            CR.U8;
          end;
          CR.S16;
        end;
      end
      else
        for var I := 0 to Count - 1 do
        begin
          C.FontAdvances[I] := 512;
          if C.Kind = 75 then
            C.FontAdvances[I] := 10240;
        end;
    finally
      CR.Free;
    end;
  end;
end;

procedure TSWFMovie.ParseText(C: TSWFCharacter; R: TSWFReader);
var
  GlyphBits, AdvanceBits, Flags, Count: Integer;
  RecordValue: TSWFTextRecord;
begin
  C.Bounds := R.Rect;
  C.TextMatrix := R.Matrix;
  GlyphBits := R.U8;
  AdvanceBits := R.U8;
  RecordValue := Default(TSWFTextRecord);
  RecordValue.Color := $FF000000;
  while True do
  begin
    R.Align;
    Flags := R.U8;
    if Flags = 0 then
      Break;
    if (Flags and $80) = 0 then
      raise ESWFError.Create('Invalid SWF text record');
    if (Flags and 8) <> 0 then
      RecordValue.FontId := R.U16;
    if (Flags and 4) <> 0 then
      RecordValue.Color := SWFColor(R, C.Kind = 33);
    if (Flags and 1) <> 0 then
      RecordValue.X := R.S16;
    if (Flags and 2) <> 0 then
      RecordValue.Y := R.S16;
    if (Flags and 8) <> 0 then
      RecordValue.Height := R.U16;
    Count := R.U8;
    SetLength(RecordValue.Glyphs, Count);
    for var I := 0 to Count - 1 do
    begin
      RecordValue.Glyphs[I].Index := R.Bits(GlyphBits);
      RecordValue.Glyphs[I].Advance := R.SignedBits(AdvanceBits);
    end;
    C.TextRecords := C.TextRecords + [RecordValue];
    RecordValue.Glyphs := nil;
    for var G in C.TextRecords[High(C.TextRecords)].Glyphs do
      Inc(RecordValue.X, G.Advance);
  end;
end;

function SWFColor(R: TSWFReader; Alpha: Boolean): Cardinal;
var
  Red, Green, Blue, A: Cardinal;
begin
  Red := R.U8;
  Green := R.U8;
  Blue := R.U8;
  A := 255;
  if Alpha then
    A := R.U8;
  Result := (A shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

constructor TSWFMovie.Create(const Data: TBytes);
var
  R: TSWFReader;
  Raw: TBytes;
  Count: Integer;
begin
  inherited Create;
  Characters := TObjectDictionary<Integer, TSWFCharacter>.Create([doOwnsValues]);
  Sounds := TObjectDictionary<Integer, TSWFSound>.Create([doOwnsValues]);
  ButtonSounds := TDictionary<Integer, TSWFButtonSounds>.Create;
  FStreamSounds := TObjectList<TSWFSound>.Create;
  ExportNames := TDictionary<string, Integer>.Create;
  SymbolNames := TDictionary<Integer, string>.Create;
  AVM2SymbolNames := TDictionary<Integer, string>.Create;
  AVM2ExportNames := TDictionary<string, Integer>.Create;
  Warnings := TStringList.Create;
  Warnings.Sorted := True;
  Warnings.Duplicates := dupIgnore;
  Background := $FFFFFFFF;
  Raw := DecodeSWF(Data);
  Version := Raw[3];
  DecodedSize := Length(Raw);
  R := TSWFReader.Create(Copy(Raw, 8, Length(Raw) - 8), Version);
  try
    Stage := R.Rect;
    Width := Ceil((Int64(Stage.Right) - Stage.Left) / 20);
    Height := Ceil((Int64(Stage.Bottom) - Stage.Top) / 20);
    if (Width < 1) or (Height < 1) or (Width > 4096) or (Height > 4096) or
      (Int64(Width) * Height > 8 * 1024 * 1024) then
      raise ESWFError.Create('Invalid or excessive SWF stage size');
    FPS := R.U16 / 256;
    Count := R.U16;
    if (FPS <= 0) or (FPS > 240) then
      raise ESWFError.Create('Invalid SWF frame rate');
    ParseTimeline(R, Count, 0, Frames);
  finally
    FJPEGTables := nil;
    R.Free;
  end;
end;

destructor TSWFMovie.Destroy;
begin
  Warnings.Free;
  SceneFrameLabels.Free;
  AVM2ExportNames.Free;
  AVM2SymbolNames.Free;
  SymbolNames.Free;
  ExportNames.Free;
  ButtonSounds.Free;
  FStreamSounds.Free;
  Sounds.Free;
  Characters.Free;
  inherited;
end;

procedure TSWFMovie.Warn(const Text: string);
begin
  if Warnings.Count < 256 then
    Warnings.Add(Text);
end;

function TSWFMovie.GetBitmapMemorySize: Integer;
begin
  Result := FBitmapPixels * SizeOf(Cardinal);
end;

function TSWFMovie.SoundMemorySize: Integer;
begin
  Result := FSoundSamples * SizeOf(SmallInt);
end;

procedure TSWFMovie.ParseSound(Id: Word; R: TSWFReader);
var
  Sound: TSWFSound;
begin
  if Characters.ContainsKey(Id) or Sounds.ContainsKey(Id) then
    raise ESWFError.Create('Duplicate SWF sound character');
  try
    Sound := ReadSWFSound(R, SWFMovieSoundSampleLimit - FSoundSamples);
  except
    on E: ESWFError do
    begin
      Warn(Format('Sound %d: %s', [Id, E.Message]));
      Exit;
    end;
  end;
  Sounds.Add(Id, Sound);
  Inc(FSoundSamples, Length(Sound.Samples));
end;

procedure TSWFMovie.DecodeTimelineSound(var Frames: TArray<TSWFFrame>);
var
  Format: TSWFStreamFormat;
  Decoder: TSWFStreamDecoder;
  Body: TSWFReader;
  I, J, Code, Position, Declared, AnchorFrame, AnchorPosition: Integer;
  SegmentFirst, SegmentLast, SegmentOffset, BlockOffset: Integer;
  Buffered: Int64;
  HasFormat, FirstBlock, SeenBlock: Boolean;

  procedure CloseSegment;
  var
    Index, EndOffset: Integer;
  begin
    if SegmentFirst >= 0 then
    begin
      EndOffset := Decoder.FrameCount;
      for Index := SegmentFirst to SegmentLast do
        if Frames[Index].StreamSound = Decoder.Sound then
        begin
          if Frames[Index].StreamOffset < EndOffset then
            Frames[Index].StreamEnd := EndOffset
          else
            Frames[Index].StreamSound := nil;
        end;
    end;
    SegmentFirst := -1;
    AnchorFrame := -1;
    Buffered := 0;
  end;

  procedure FinishStream;
  var
    Sound: TSWFSound;
  begin
    CloseSegment;
    if Decoder <> nil then
    begin
      Sound := Decoder.Finish;
      if Length(Sound.Samples) > 0 then
      begin
        FStreamSounds.Add(Sound);
        Inc(FSoundSamples, Length(Sound.Samples));
      end
      else
        Sound.Free;
      FreeAndNil(Decoder);
    end;
  end;

  procedure SetFramePosition;
  begin
    if SegmentFirst < 0 then
    begin
      SegmentFirst := I;
      SegmentOffset := BlockOffset;
    end;
    SegmentLast := I;
    Frames[I].StreamSound := Decoder.Sound;
    Frames[I].StreamOffset := Max(SegmentOffset, Position);
  end;

begin
  Decoder := nil;
  Format := Default(TSWFStreamFormat);
  HasFormat := False;
  FirstBlock := True;
  SegmentFirst := -1;
  SegmentLast := -1;
  SegmentOffset := 0;
  AnchorFrame := -1;
  AnchorPosition := 0;
  Buffered := 0;
  try
    for I := 0 to High(Frames) do
    begin
      SeenBlock := False;
      for J := 0 to High(Frames[I].Tags) do
      begin
        Code := Frames[I].Tags[J].Code;
        if not (Code in [18, 19, 45]) then
          Continue;
        Body := TSWFReader.Create(Frames[I].Tags[J].Data, Version);
        Frames[I].Tags[J].Data := nil;
        try
          try
            if Code in [18, 45] then
            begin
              FinishStream;
              HasFormat := False;
              Format := ReadSWFStreamFormat(Body);
              HasFormat := True;
              FirstBlock := True;
            end
            else if not SeenBlock then
            begin
              SeenBlock := True;
              if not HasFormat then
                Continue;
              if Decoder = nil then
                Decoder := TSWFStreamDecoder.Create(Format, SWFMovieSoundSampleLimit - FSoundSamples);
              BlockOffset := Decoder.FrameCount;
              if Decoder.AddBlock(Body, FirstBlock, Position, Declared) then
              begin
                FirstBlock := False;
                AnchorFrame := I;
                AnchorPosition := Position;
                SetFramePosition;
              end
              else if Format.Codec = 2 then
              begin
                // At high frame rates MP3 blocks can contain only their header.
                // Their timeline time is still a usable seek point in the segment.
                if AnchorFrame >= 0 then
                  Position := Min(SWFMovieSoundSampleLimit,
                    AnchorPosition + Round((I - AnchorFrame) * Double(Format.SampleRate) / FPS))
                else
                  Position := BlockOffset + Format.Latency;
                SetFramePosition;
              end;
              Inc(Buffered, Declared);
            end;
          except
            on E: ESWFSoundUnsupported do
            begin
              Warn(E.Message);
              HasFormat := False;
            end;
            on E: ESWFSoundLimit do
            begin
              Warn('SWF stream audio: ' + E.Message);
              FinishStream;
              HasFormat := False;
            end;
            on E: ESWFError do
            begin
              Warn('SWF stream audio: ' + E.Message);
              FinishStream;
            end;
          end;
        finally
          Body.Free;
        end;
      end;
      if Decoder <> nil then
      begin
        if Format.Codec = 2 then
          Dec(Buffered, Format.AverageFrames);
        // PCM and ADPCM gaps end a segment. MP3 may cover a frame without a
        // block using the surplus samples from previously decoded MPEG frames.
        if not SeenBlock and ((Format.Codec <> 2) or (Buffered <= -Format.AverageFrames)) then
          CloseSegment;
      end;
    end;
    FinishStream;
  finally
    Decoder.Free;
  end;
end;

procedure TSWFMovie.ParseBitmap(C: TSWFCharacter; R: TSWFReader);
var
  Image: TRasterImage;
  MaxPixels: Integer;
begin
  MaxPixels := Min(SWFBitmapPixelLimit, SWFMovieBitmapPixelLimit - FBitmapPixels);
  try
    if C.Kind in [20, 36] then
      Image := DecodeSWFLossless(R, C.Kind = 36, MaxPixels)
    else
      Image := DecodeSWFJPEG(R, C.Kind, FJPEGTables, MaxPixels);
  except
    on E: ESWFBitmapUnsupported do
    begin
      Warn(Format('Bitmap %d: %s', [C.Id, E.Message]));
      Exit;
    end;
  end;
  C.BitmapWidth := Image.Width;
  C.BitmapHeight := Image.Height;
  C.BitmapPixels := Image.Pixels;
  Inc(FBitmapPixels, Length(C.BitmapPixels));
  C.Bounds.Right := C.BitmapWidth * 20;
  C.Bounds.Bottom := C.BitmapHeight * 20;
  C.ShapeBounds := TSWFBounds.FromRect(C.Bounds);
  C.PathBounds := C.ShapeBounds;
end;

procedure TSWFMovie.ParseVideo(C: TSWFCharacter; R: TSWFReader);
var
  Count, VideoWidth, VideoHeight, Flags, Codec: Integer;
begin
  Count := R.U16;
  VideoWidth := R.U16;
  VideoHeight := R.U16;
  Flags := R.U8;
  Codec := R.U8;
  C.Video := TSWFVideoStream.Create(VideoWidth, VideoHeight, Count, Codec, Flags and 1 <> 0, (Flags shr 1) and 7);
  C.Bounds.Right := VideoWidth * 20;
  C.Bounds.Bottom := VideoHeight * 20;
  C.ShapeBounds := TSWFBounds.FromRect(C.Bounds);
  C.PathBounds := C.ShapeBounds;
  if not (Codec in [0, SWFSorensonSparkCodec, SWFScreenVideoCodec, SWFVP6Codec, SWFVP6AlphaCodec, SWFScreenVideo2Codec]) then
    Warn(Format('Video %d uses unsupported codec %d', [C.Id, Codec]));
end;

procedure TSWFMovie.ParseSceneData(R: TSWFReader; FrameCount: Integer);
var
  Count, Offset: Cardinal;
  Index: Integer;
  Name: string;
begin
  Count := R.EncodedU32;
  if (Count > 65535) or (Count > Cardinal(R.Remaining div 2)) then
    raise ESWFError.Create('Invalid SWF scene count');
  SetLength(SceneLabels, Integer(Count));
  for Index := 0 to High(SceneLabels) do
  begin
    Offset := R.EncodedU32;
    SceneLabels[Index].StartFrame := Integer(Min(Offset, Cardinal(FrameCount)));
    SceneLabels[Index].Name := R.Str;
  end;
  Count := R.EncodedU32;
  if (Count > 65535) or (Count > Cardinal(R.Remaining div 2)) then
    raise ESWFError.Create('Invalid SWF frame label count');
  if SceneFrameLabels = nil then
    SceneFrameLabels := TDictionary<string, Integer>.Create
  else
    SceneFrameLabels.Clear;
  for Index := 1 to Integer(Count) do
  begin
    Offset := R.EncodedU32;
    Name := R.Str;
    if Offset < Cardinal(FrameCount) then
      SceneFrameLabels.AddOrSetValue(Name, Integer(Offset));
  end;
end;

procedure TSWFMovie.ParseTimeline(R: TSWFReader; Count, Nesting: Integer; out Frames: TArray<TSWFFrame>);
var
  Tags: TList<TSWFTag>;
  List: TList<TSWFFrame>;
  Tag: TSWFTag;
  Size: Cardinal;
  Header, Id, N: Integer;
  Body: TSWFReader;
  C: TSWFCharacter;
  F: TSWFFrame;
  ExportName: string;
  ButtonAudio: TSWFButtonSounds;
  Slot: Integer;
begin
  if Nesting > 64 then
    raise ESWFError.Create('SWF timeline nesting/frame count limit');
  Tags := TList<TSWFTag>.Create;
  List := TList<TSWFFrame>.Create;
  try
    while R.Remaining > 0 do
    begin
      Inc(FTagCount);
      if FTagCount > 1000000 then
        raise ESWFError.Create('SWF tag limit');
      Tag.Ordinal := FTagCount;
      Header := R.U16;
      Tag.Code := Header shr 6;
      Size := Header and 63;
      if Size = 63 then
        Size := R.U32;
      if Size > Cardinal(R.Remaining) then
        raise ESWFError.Create('Truncated SWF tag');
      Tag.Data := R.Bytes(Integer(Size));
      if Tag.Code = 0 then
        Break;
      if Tag.Code = 1 then
      begin
        F := Default(TSWFFrame);
        F.Tags := Tags.ToArray;
        List.Add(F);
        Tags.Clear;
        if List.Count > 65535 then
          raise ESWFError.Create('SWF frame limit');
        Continue;
      end;
      Body := TSWFReader.Create(Tag.Data, Version);
      try
        case Tag.Code of
          2, 22, 32, 83, 46, 84, 39, 10, 48, 75, 11, 33, 37, 6, 21, 35, 20, 36, 90, 7, 34, 60:
            begin
              Id := Body.U16;
              if Characters.ContainsKey(Id) or Sounds.ContainsKey(Id) then
                raise ESWFError.Create('Duplicate SWF character');
              if Characters.Count >= 65535 then
                raise ESWFError.Create('SWF character limit');
              C := TSWFCharacter.Create;
              C.Id := Id;
              C.Kind := Tag.Code;
              if not (Tag.Code in [6, 21, 35, 20, 36, 46, 60, 84, 90]) then
                C.Data := Copy(Tag.Data, 2, Length(Tag.Data) - 2);
              Characters.Add(Id, C);
              case Tag.Code of
                2:
                  ParseShape(C, Body, 1);
                22:
                  ParseShape(C, Body, 2);
                32:
                  ParseShape(C, Body, 3);
                83:
                  ParseShape(C, Body, 4);
                46, 84:
                  ParseMorphShape(C, Body);
                39:
                  begin
                    N := Body.U16;
                    ParseTimeline(Body, N, Nesting + 1, C.Frames);
                  end;
                10, 48, 75:
                  ParseFont(C, Body);
                11, 33:
                  ParseText(C, Body);
                6, 21, 35, 20, 36, 90:
                  ParseBitmap(C, Body);
                7, 34:
                  ParseButton(C, Body);
                60:
                  ParseVideo(C, Body);
              end;
            end;
          61:
            begin
              Id := Body.U16;
              N := Body.U16;
              if not Characters.TryGetValue(Id, C) or (C.Video = nil) then
                Warn(Format('VideoFrame links missing video stream %d', [Id]))
              else if C.Video.Codec in [SWFSorensonSparkCodec, SWFScreenVideoCodec, SWFVP6Codec, SWFVP6AlphaCodec, SWFScreenVideo2Codec] then
                C.Video.AddFrame(N, Body.Bytes(Body.Remaining));
            end;
          8:
            if (Nesting = 0) and (Length(FJPEGTables) = 0) then
              FJPEGTables := Tag.Data;
          9:
            begin
              if Nesting = 0 then
                Background := SWFColor(Body, False);
            end;
          14:
            begin
              Id := Body.U16;
              ParseSound(Id, Body);
            end;
          17:
            begin
              Id := Body.U16;
              for Slot := Low(ButtonAudio) to High(ButtonAudio) do
                ButtonAudio[Slot] := ReadSWFSoundEvent(Body);
              ButtonSounds.AddOrSetValue(Id, ButtonAudio);
            end;
          69:
            if Body.U32 and 8 <> 0 then
              UsesAVM2 := True;
          72, 82:
            begin
              if Nesting <> 0 then
                raise ESWFError.Create('DoABC must be in the main SWF timeline');
              UsesAVM2 := True;
              Tags.Add(Tag);
            end;
          76:
            begin
              N := Body.U16;
              for var I := 1 to N do
              begin
                Id := Body.U16;
                ExportName := Body.Str;
                if Id = 0 then
                  DocumentClass := ExportName
                else
                begin
                  AVM2SymbolNames.AddOrSetValue(Id, ExportName);
                  AVM2ExportNames.AddOrSetValue(ExportName, Id);
                end;
              end;
              if Body.Remaining <> 0 then
                raise ESWFError.Create('Unexpected data after SymbolClass');
            end;
          56:
            begin
              N := Body.U16;
              for var I := 1 to N do
              begin
                Id := Body.U16;
                ExportName := Body.Str;
              { Export lookup is case-insensitive, including in SWF7+. }
                ExportNames.AddOrSetValue(AVMLowerName(ExportName), Id);
                SymbolNames.AddOrSetValue(Id, ExportName);
              end;
              Tags.Add(Tag);
            end;
          59:
            begin
              if Nesting = 0 then
              begin
                Body.U16;
                InitActions := InitActions + [Body.Bytes(Body.Remaining)];
              end
              else
                Tags.Add(Tag);
            end;
          12, 15, 18, 19, 26, 28, 4, 5, 43, 45, 70:
            Tags.Add(Tag);
          86:
            if Nesting = 0 then
              ParseSceneData(Body, Max(1, Count));
          24, 58, 64, 65, 66, 77, 63, 41:
            ; // Protection, metadata and authoring data.
        else
          Warn(Format('SWF tag %d is not implemented', [Tag.Code]));
        end;
      finally
        Body.Free;
      end;
    end;
    { Treats the end of a clip without ShowFrame tags as its first
      ShowFrame, including an entirely empty DefineSprite. }
    if List.Count = 0 then
    begin
      F := Default(TSWFFrame);
      F.Tags := Tags.ToArray;
      List.Add(F);
      Tags.Clear;
    end;
    if (Tags.Count <> 0) or (List.Count <> Max(1, Count)) then
      raise ESWFError.Create('SWF timeline frame count mismatch');
    Frames := List.ToArray;
    DecodeTimelineSound(Frames);
  finally
    Tags.Free;
    List.Free;
  end;
end;

function ReadShapeSegment(R: TSWFReader; var X, Y: Integer): TSWFShapeSegment;
var
  N, DX, DY: Integer;
begin
  Result.X1 := X;
  Result.Y1 := Y;
  Result.Curved := R.Bits(1) = 0;
  N := R.Bits(4) + 2;
  if Result.Curved then
  begin
    Result.CX := SWFAddCoordinate(X, R.SignedBits(N));
    Result.CY := SWFAddCoordinate(Y, R.SignedBits(N));
    X := SWFAddCoordinate(Result.CX, R.SignedBits(N));
    Y := SWFAddCoordinate(Result.CY, R.SignedBits(N));
  end
  else
  begin
    DX := 0;
    DY := 0;
    if R.Bits(1) <> 0 then
    begin
      DX := R.SignedBits(N);
      DY := R.SignedBits(N);
    end
    else if R.Bits(1) <> 0 then
      DY := R.SignedBits(N)
    else
      DX := R.SignedBits(N);
    Result.CX := SWFAddCoordinate(X, DX div 2);
    Result.CY := SWFAddCoordinate(Y, DY div 2);
    X := SWFAddCoordinate(X, DX);
    Y := SWFAddCoordinate(Y, DY);
  end;
  Result.X2 := X;
  Result.Y2 := Y;
end;

function ReadShapeStyleCount(R: TSWFReader; Extended: Boolean): Integer;
begin
  Result := R.U8;
  if (Result = 255) and Extended then
    Result := R.U16;
end;

function ShapeStyleIndex(Index, Base, Count: Integer): Integer;
begin
  if (Index > 0) and (Index <= Count) then
    Result := Base + Index
  else
    Result := 0;
end;

function ReadShapeStrokeFlags(R: TSWFReader; out HasFill, PixelHint: Boolean): TSWFStroke;
var
  Flags, Cap, Join: Integer;
begin
  Result := Default(TSWFStroke);
  Flags := R.Bits(16);
  R.Align;
  Cap := Flags shr 14;
  if Cap <= Ord(High(TSWFLineCap)) then
    Result.StartCap := TSWFLineCap(Cap);
  Cap := Flags and 3;
  if Cap <= Ord(High(TSWFLineCap)) then
    Result.EndCap := TSWFLineCap(Cap);
  Join := (Flags shr 12) and 3;
  if Join <= Ord(High(TSWFLineJoin)) then
    Result.Join := TSWFLineJoin(Join);
  if Result.Join = ljMiter then
    Result.MiterLimit := R.U16 / 256;
  Result.NoHScale := (Flags and $400) <> 0;
  Result.NoVScale := (Flags and $200) <> 0;
  Result.NoClose := (Flags and 4) <> 0;
  HasFill := (Flags and $800) <> 0;
  PixelHint := (Flags and $100) <> 0;
end;

type
  TSWFShapeGeometry = class
  private
    FEdges: TList<TSWFEdge>;
    FStrokes: TList<TSWFStrokePath>;
    FStrokePoints: TList<TSWFPoint>;
    FEdgeCount, FCurrentStroke: Integer;
    FPathBounds: TSWFBounds;
    FTrackBounds: Boolean;
    procedure AddEdge(AX, AY, BX, BY: Double; Fill0, Fill1, Stroke: Integer);
    procedure AddPoint(X, Y: Double);
  public
    constructor Create(TrackBounds: Boolean);
    destructor Destroy; override;
    procedure FinishStroke;
    procedure Add(const Segment: TSWFShapeSegment; Fill0, Fill1, Stroke: Integer);
    procedure Store(Shape: TSWFCharacter);
  end;

constructor TSWFShapeGeometry.Create(TrackBounds: Boolean);
begin
  inherited Create;
  FEdges := TList<TSWFEdge>.Create;
  FStrokes := TList<TSWFStrokePath>.Create;
  FStrokePoints := TList<TSWFPoint>.Create;
  FTrackBounds := TrackBounds;
  FPathBounds := TSWFBounds.Empty;
end;

destructor TSWFShapeGeometry.Destroy;
begin
  FStrokePoints.Free;
  FStrokes.Free;
  FEdges.Free;
  inherited;
end;

procedure TSWFShapeGeometry.FinishStroke;
var
  Path: TSWFStrokePath;
begin
  if FStrokePoints.Count = 0 then
    Exit;
  Path.Fill := FCurrentStroke;
  Path.Points := FStrokePoints.ToArray;
  FStrokes.Add(Path);
  FStrokePoints.Clear;
end;

procedure TSWFShapeGeometry.AddPoint(X, Y: Double);
var
  Point: TSWFPoint;
begin
  Point.X := X;
  Point.Y := Y;
  FStrokePoints.Add(Point);
end;

procedure TSWFShapeGeometry.AddEdge(AX, AY, BX, BY: Double; Fill0, Fill1, Stroke: Integer);
var
  Edge: TSWFEdge;
begin
  Inc(FEdgeCount);
  if FEdgeCount > 1000000 then
    raise ESWFError.Create('SWF shape edge limit');
  if Stroke <> 0 then
  begin
    if FStrokePoints.Count = 0 then
    begin
      FCurrentStroke := Stroke;
      AddPoint(AX, AY);
    end;
    AddPoint(BX, BY);
  end;
  if Fill0 <> 0 then
  begin
    Edge.X1 := AX;
    Edge.Y1 := AY;
    Edge.X2 := BX;
    Edge.Y2 := BY;
    Edge.Fill := Fill0;
    FEdges.Add(Edge);
  end;
  if Fill1 <> 0 then
  begin
    Edge.X1 := BX;
    Edge.Y1 := BY;
    Edge.X2 := AX;
    Edge.Y2 := AY;
    Edge.Fill := Fill1;
    FEdges.Add(Edge);
  end;
end;

procedure TSWFShapeGeometry.Add(const Segment: TSWFShapeSegment; Fill0, Fill1, Stroke: Integer);
var
  I: Integer;
  PX, PY, QX, QY, T, U: Double;
begin
  if FTrackBounds and ((Fill0 <> 0) or (Fill1 <> 0) or (Stroke <> 0)) then
  begin
    if Segment.Curved then
      FPathBounds.Include(TSWFBounds.Quadratic(Segment.X1, Segment.Y1, Segment.CX, Segment.CY,
          Segment.X2, Segment.Y2))
    else
      FPathBounds.Include(TSWFBounds.Line(Segment.X1, Segment.Y1, Segment.X2, Segment.Y2));
  end;
  if not Segment.Curved then
  begin
    AddEdge(Segment.X1, Segment.Y1, Segment.X2, Segment.Y2, Fill0, Fill1, Stroke);
    Exit;
  end;
  PX := Segment.X1;
  PY := Segment.Y1;
  for I := 1 to 12 do
  begin
    T := I / 12;
    U := 1 - T;
    QX := U * U * Segment.X1 + 2 * U * T * Segment.CX + T * T * Segment.X2;
    QY := U * U * Segment.Y1 + 2 * U * T * Segment.CY + T * T * Segment.Y2;
    AddEdge(PX, PY, QX, QY, Fill0, Fill1, Stroke);
    PX := QX;
    PY := QY;
  end;
end;

procedure TSWFShapeGeometry.Store(Shape: TSWFCharacter);
begin
  FinishStroke;
  Shape.Edges := FEdges.ToArray;
  Shape.StrokePaths := FStrokes.ToArray;
  if FTrackBounds then
    Shape.PathBounds := FPathBounds;
end;

procedure TSWFMovie.ParseShape(C: TSWFCharacter; R: TSWFReader; Version: Integer);
var
  Geometry: TSWFShapeGeometry;
  FillBits, LineBits, F0, F1, FillBase, FillCount, LineBase, LineCount: Integer;
  X, Y, Flags, N, LineStyleIndex: Integer;
  Fill: TSWFFill;
  Segment: TSWFShapeSegment;

  function ReadFill: TSWFFill;
  var
    Kind, Flags, Index: Integer;
  begin
    Result := Default(TSWFFill);
    Kind := R.U8;
    case Kind of
      0:
        Result.Color := SWFColor(R, Version >= 3);
      $10, $12, $13:
        begin
          case Kind of
            $10:
              Result.Gradient.Kind := sgLinear;
            $12:
              Result.Gradient.Kind := sgRadial;
            $13:
              Result.Gradient.Kind := sgFocal;
          end;
          Result.Gradient.Matrix := R.Matrix;
          Flags := R.U8;
          if Version >= 4 then
          begin
            case Flags shr 6 of
              1:
                Result.Gradient.Spread := gsReflect;
              2:
                Result.Gradient.Spread := gsRepeat;
            end;
            Result.Gradient.LinearRGB := ((Flags shr 4) and 3) = 1;
          end;
          SetLength(Result.Gradient.Stops, Flags and 15);
          for Index := 0 to High(Result.Gradient.Stops) do
          begin
            Result.Gradient.Stops[Index].Ratio := R.U8;
            Result.Gradient.Stops[Index].Color := SWFColor(R, Version >= 3);
          end;
          if Kind = $13 then
            Result.Gradient.Focal := R.S16 / 256;
        end;
      $40..$43:
        begin
          Result.BitmapId := R.U16;
          if Result.BitmapId = 0 then
            Result.BitmapId := $FFFF;
          Result.BitmapMatrix := R.Matrix;
          Result.BitmapRepeat := (Kind and 1) = 0;
          Result.BitmapSmooth := (Self.Version >= 8) and ((Kind and 2) = 0);
        end;
    else
      raise ESWFError.Create('Unsupported SWF fill style');
    end;
  end;

  function ReadLine: TSWFFill;
  var
    Line: TSWFStroke;
    Width: Integer;
    HasFill, PixelHint: Boolean;
  begin
    Width := R.U16;
    Line := Default(TSWFStroke);
    Result := Default(TSWFFill);
    if Version < 4 then
      Result.Color := SWFColor(R, Version >= 3)
    else
    begin
      Line := ReadShapeStrokeFlags(R, HasFill, PixelHint);
      if PixelHint then
        Warn('Shape4 stroke pixel hinting is not implemented');
      if HasFill then
        Result := ReadFill
      else
        Result.Color := SWFColor(R, True);
    end;
    Line.Width := Width;
    Result.Stroke := True;
    Result.Line := Line;
  end;

  procedure Styles;
  var
    Index: Integer;
  begin
    FillCount := ReadShapeStyleCount(R, Version >= 2);
    FillBase := Length(C.Fills);
    SetLength(C.Fills, FillBase + FillCount);
    for Index := 0 to FillCount - 1 do
      C.Fills[FillBase + Index] := ReadFill;

    LineCount := ReadShapeStyleCount(R, Version >= 2);
    LineBase := Length(C.Fills);
    SetLength(C.Fills, LineBase + LineCount);
    for Index := 0 to LineCount - 1 do
      C.Fills[LineBase + Index] := ReadLine;
  end;

begin
  if Version <> 0 then
    C.Bounds := R.Rect;
  if Version <> 0 then
    C.ShapeBounds := TSWFBounds.FromRect(C.Bounds);
  C.EvenOddFills := Version <> 0;
  if Version = 4 then
  begin
    C.PathBounds := TSWFBounds.FromRect(R.Rect);
    C.EvenOddFills := (R.U8 and 4) = 0;
  end;
  Geometry := TSWFShapeGeometry.Create(Version <> 4);
  try
    if Version = 0 then
    begin
      Fill := Default(TSWFFill);
      Fill.Color := $FF000000;
      C.Fills := [Fill];
      FillCount := 1;
      FillBase := 0;
      LineCount := 0;
      LineBase := 0;
    end
    else
      Styles;
    FillBits := R.Bits(4);
    LineBits := R.Bits(4);
    X := 0;
    Y := 0;
    F0 := 0;
    F1 := 0;
    LineStyleIndex := 0;
    while True do
    begin
      if R.Bits(1) <> 0 then
      begin
        Segment := ReadShapeSegment(R, X, Y);
        Geometry.Add(Segment, ShapeStyleIndex(F0, FillBase, FillCount),
          ShapeStyleIndex(F1, FillBase, FillCount), ShapeStyleIndex(LineStyleIndex, LineBase, LineCount));
        Continue;
      end;
      Flags := R.Bits(5);
      if Flags = 0 then
        Break;
      if (Flags and $19) <> 0 then
        Geometry.FinishStroke;
      if (Flags and 1) <> 0 then
      begin
        N := R.Bits(5);
        X := R.SignedBits(N);
        Y := R.SignedBits(N);
      end;
      if (Flags and 2) <> 0 then
        F0 := R.Bits(FillBits);
      if (Flags and 4) <> 0 then
        F1 := R.Bits(FillBits);
      if (Flags and 8) <> 0 then
        LineStyleIndex := R.Bits(LineBits);
      if (Flags and 16) <> 0 then
      begin
        if Version = 0 then
          raise ESWFError.Create('Font glyph cannot introduce styles');
        R.Align;
        Styles;
        FillBits := R.Bits(4);
        LineBits := R.Bits(4);
      end;
    end;
    R.Align;
    Geometry.Store(C);
  finally
    Geometry.Free;
  end;
end;

type
  TSWFMorphWeight = record
    A, B: Double;
    procedure Initialize(Ratio: Word);
    function Coordinate(StartValue, EndValue: Integer): Integer;
    function ByteValue(StartValue, EndValue: Byte): Byte;
    function Color(StartValue, EndValue: Cardinal): Cardinal;
    function FixedPoint(StartValue, EndValue: Double; UnitValue: Integer): Double;
    function Matrix(const StartValue, EndValue: TSWFMatrix): TSWFMatrix;
  end;

procedure TSWFMorphWeight.Initialize(Ratio: Word);
begin
  B := SWFFloat32(Ratio / 65535.0);
  A := SWFFloat32(1 - B);
end;

function TSWFMorphWeight.Coordinate(StartValue, EndValue: Integer): Integer;
var
  Value: Double;
begin
  Value := SWFMatrixProduct(SWFFloat32(StartValue), A, SWFFloat32(EndValue), B);
  if Value >= High(Integer) then
    Exit(High(Integer));
  if Value <= Low(Integer) then
    Exit(Low(Integer));
  if Value >= 0 then
    Result := Trunc(Value + 0.5)
  else
    Result := -Trunc(0.5 - Value);
end;

function TSWFMorphWeight.ByteValue(StartValue, EndValue: Byte): Byte;
begin
  Result := EnsureRange(Trunc(SWFMatrixProduct(StartValue, A, EndValue, B)), 0, 255);
end;

function TSWFMorphWeight.Color(StartValue, EndValue: Cardinal): Cardinal;
var
  Shift: Integer;
begin
  Result := 0;
  for Shift := 0 to 3 do
    Result := Result or
      (Cardinal(ByteValue(Byte(StartValue shr (Shift * 8)), Byte(EndValue shr (Shift * 8)))) shl (Shift * 8));
end;

function TSWFMorphWeight.FixedPoint(StartValue, EndValue: Double; UnitValue: Integer): Double;
var
  LeftProduct, RightProduct: Int64;
begin
  // Both fixed-point products round toward negative infinity independently.
  LeftProduct := Trunc(StartValue * UnitValue) * Trunc(A * UnitValue);
  RightProduct := Trunc(EndValue * UnitValue) * Trunc(B * UnitValue);
  Result := (Floor(LeftProduct / UnitValue) + Floor(RightProduct / UnitValue)) / UnitValue;
end;

function TSWFMorphWeight.Matrix(const StartValue, EndValue: TSWFMatrix): TSWFMatrix;
begin
  Result.A := FixedPoint(StartValue.A, EndValue.A, 65536);
  Result.B := FixedPoint(StartValue.B, EndValue.B, 65536);
  Result.C := FixedPoint(StartValue.C, EndValue.C, 65536);
  Result.D := FixedPoint(StartValue.D, EndValue.D, 65536);
  Result.TX := Coordinate(Trunc(StartValue.TX), Trunc(EndValue.TX));
  Result.TY := Coordinate(Trunc(StartValue.TY), Trunc(EndValue.TY));
end;

procedure BuildMorphGeometry(Shape: TSWFCharacter; const Segments: TArray<TSWFMorphSegment>; Ratio: Word; TrackBounds: Boolean);
var
  Geometry: TSWFShapeGeometry;
  Weight: TSWFMorphWeight;
  Pair: TSWFMorphSegment;
  Edge: TSWFShapeSegment;
begin
  Weight.Initialize(Ratio);
  Geometry := TSWFShapeGeometry.Create(TrackBounds);
  try
    for Pair in Segments do
    begin
      if Pair.BreakStroke then
        Geometry.FinishStroke;
      if Ratio = 0 then
        Edge := Pair.First
      else if Ratio = High(Word) then
        Edge := Pair.Last
      else
      begin
        Edge.Curved := Pair.First.Curved or Pair.Last.Curved;
        Edge.X1 := Weight.Coordinate(Pair.First.X1, Pair.Last.X1);
        Edge.Y1 := Weight.Coordinate(Pair.First.Y1, Pair.Last.Y1);
        Edge.X2 := Weight.Coordinate(Pair.First.X2, Pair.Last.X2);
        Edge.Y2 := Weight.Coordinate(Pair.First.Y2, Pair.Last.Y2);
        if Edge.Curved then
        begin
          Edge.CX := Weight.Coordinate(Pair.First.CX, Pair.Last.CX);
          Edge.CY := Weight.Coordinate(Pair.First.CY, Pair.Last.CY);
        end;
      end;
      Geometry.Add(Edge, Pair.Fill0, Pair.Fill1, Pair.Stroke);
    end;
    Geometry.Store(Shape);
  finally
    Geometry.Free;
  end;
end;

function TSWFCharacter.ShapeAt(Ratio: Word): TSWFCharacter;
var
  Weight: TSWFMorphWeight;
  Shape: TSWFCharacter;
  Style, Last: TSWFFill;
  I, J: Integer;
begin
  if (FMorph = nil) or (Ratio = 0) then
    Exit(Self);
  if (FMorph.Frame <> nil) and (FMorph.FrameRatio = Ratio) then
    Exit(FMorph.Frame);
  Weight.Initialize(Ratio);
  Shape := TSWFCharacter.Create;
  try
    Shape.Kind := Kind;
    Shape.EvenOddFills := True;
    if Ratio = High(Word) then
      Shape.Fills := FMorph.EndFills
    else
    begin
      SetLength(Shape.Fills, Length(Fills));
      for I := 0 to High(Fills) do
      begin
        Style := Fills[I];
        Last := FMorph.EndFills[I];
        if Style.Stroke then
          Style.Line.Width := Weight.Coordinate(Style.Line.Width, Last.Line.Width);
        if Style.Gradient.Kind <> sgNone then
        begin
          Style.Gradient.Matrix := Weight.Matrix(Style.Gradient.Matrix, Last.Gradient.Matrix);
          if Style.Gradient.Kind = sgFocal then
            Style.Gradient.Focal := Weight.FixedPoint(Style.Gradient.Focal, Last.Gradient.Focal, 256);
          Style.Gradient.Stops := Copy(Style.Gradient.Stops);
          for J := 0 to High(Style.Gradient.Stops) do
          begin
            Style.Gradient.Stops[J].Ratio := Weight.ByteValue(Style.Gradient.Stops[J].Ratio,
                Last.Gradient.Stops[J].Ratio);
            Style.Gradient.Stops[J].Color := Weight.Color(Style.Gradient.Stops[J].Color,
                Last.Gradient.Stops[J].Color);
          end;
        end
        else if Style.BitmapId <> 0 then
          Style.BitmapMatrix := Weight.Matrix(Style.BitmapMatrix, Last.BitmapMatrix)
        else
          Style.Color := Weight.Color(Style.Color, Last.Color);
        Shape.Fills[I] := Style;
      end;
    end;
    BuildMorphGeometry(Shape, FMorph.Segments, Ratio, False);
    if Ratio = High(Word) then
    begin
      Shape.ShapeBounds := FMorph.EndBounds;
      Shape.PathBounds := FMorph.EndPathBounds;
      Shape.Bounds := Shape.ShapeBounds.Rect;
    end;
  except
    Shape.Free;
    raise;
  end;
  FMorph.Frame.Free;
  FMorph.Frame := Shape;
  FMorph.FrameRatio := Ratio;
  Result := Shape;
end;

procedure TSWFMovie.ParseMorphShape(C: TSWFCharacter; R: TSWFReader);
type
  TMorphStream = record
    Reader: TSWFReader;
    FillBits, LineBits, X, Y, Fill0, Fill1, Line: Integer;
    BreakStroke, AtEnd: Boolean;
    Edge: TSWFShapeSegment;
  end;
var
  Morph: TSWFMorph;
  StartStream, EndStream: TMorphStream;
  Segments: TList<TSWFMorphSegment>;
  Pair: TSWFMorphSegment;
  Boundary: Cardinal;
  FillCount, LineCount, Index: Integer;
  Advanced: Boolean;

  procedure ReadFillPair(out First, Last: TSWFFill);
  var
    Kind, Flags, Count, J: Integer;
  begin
    First := Default(TSWFFill);
    Last := Default(TSWFFill);
    Kind := StartStream.Reader.U8;
    case Kind of
      0:
        begin
          First.Color := SWFColor(StartStream.Reader, True);
          Last.Color := SWFColor(StartStream.Reader, True);
        end;
      $10, $12, $13:
        begin
          case Kind of
            $10:
              First.Gradient.Kind := sgLinear;
            $12:
              First.Gradient.Kind := sgRadial;
            $13:
              First.Gradient.Kind := sgFocal;
          end;
          First.Gradient.Matrix := StartStream.Reader.Matrix;
          Last.Gradient.Matrix := StartStream.Reader.Matrix;
          Flags := StartStream.Reader.U8;
          case Flags shr 6 of
            1:
              First.Gradient.Spread := gsReflect;
            2:
              First.Gradient.Spread := gsRepeat;
          end;
          First.Gradient.LinearRGB := ((Flags shr 4) and 3) = 1;
          Last.Gradient.Kind := First.Gradient.Kind;
          Last.Gradient.Spread := First.Gradient.Spread;
          Last.Gradient.LinearRGB := First.Gradient.LinearRGB;
          Count := Flags and 15;
          SetLength(First.Gradient.Stops, Count);
          SetLength(Last.Gradient.Stops, Count);
          for J := 0 to Count - 1 do
          begin
            First.Gradient.Stops[J].Ratio := StartStream.Reader.U8;
            First.Gradient.Stops[J].Color := SWFColor(StartStream.Reader, True);
            Last.Gradient.Stops[J].Ratio := StartStream.Reader.U8;
            Last.Gradient.Stops[J].Color := SWFColor(StartStream.Reader, True);
          end;
          if Kind = $13 then
          begin
            First.Gradient.Focal := StartStream.Reader.S16 / 256;
            Last.Gradient.Focal := StartStream.Reader.S16 / 256;
          end;
        end;
      $40..$43:
        begin
          First.BitmapId := StartStream.Reader.U16;
          if First.BitmapId = 0 then
            First.BitmapId := $FFFF;
          First.BitmapRepeat := (Kind and 1) = 0;
          First.BitmapSmooth := (Kind and 2) = 0;
          Last := First;
          First.BitmapMatrix := StartStream.Reader.Matrix;
          Last.BitmapMatrix := StartStream.Reader.Matrix;
        end;
    else
      raise ESWFError.Create('Unsupported SWF morph fill style');
    end;
  end;

  procedure ReadLinePair(out First, Last: TSWFFill);
  var
    FirstWidth, LastWidth: Integer;
    Line: TSWFStroke;
    HasFill, PixelHint: Boolean;
  begin
    FirstWidth := StartStream.Reader.U16;
    LastWidth := StartStream.Reader.U16;
    Line := Default(TSWFStroke);
    HasFill := False;
    if Advanced then
    begin
      Line := ReadShapeStrokeFlags(StartStream.Reader, HasFill, PixelHint);
      if PixelHint then
        Warn('Morph stroke pixel hinting is not implemented');
    end;
    if HasFill then
      ReadFillPair(First, Last)
    else
    begin
      First := Default(TSWFFill);
      Last := Default(TSWFFill);
      First.Color := SWFColor(StartStream.Reader, True);
      Last.Color := SWFColor(StartStream.Reader, True);
    end;
    First.Stroke := True;
    Last.Stroke := True;
    First.Line := Line;
    Last.Line := Line;
    First.Line.Width := FirstWidth;
    Last.Line.Width := LastWidth;
  end;

  procedure NextEdge(var Stream: TMorphStream);
  var
    Flags, N: Integer;
  begin
    Stream.BreakStroke := False;
    while Stream.Reader.Bits(1) = 0 do
    begin
      Flags := Stream.Reader.Bits(5);
      if Flags = 0 then
      begin
        Stream.Reader.Align;
        Stream.AtEnd := True;
        Exit;
      end;
      if (Flags and 16) <> 0 then
        raise ESWFError.Create('SWF morph changes its style tables');
      if (Flags and 1) <> 0 then
      begin
        N := Stream.Reader.Bits(5);
        Stream.X := Stream.Reader.SignedBits(N);
        Stream.Y := Stream.Reader.SignedBits(N);
      end;
      if (Flags and 2) <> 0 then
        Stream.Fill0 := Stream.Reader.Bits(Stream.FillBits);
      if (Flags and 4) <> 0 then
        Stream.Fill1 := Stream.Reader.Bits(Stream.FillBits);
      if (Flags and 8) <> 0 then
        Stream.Line := Stream.Reader.Bits(Stream.LineBits);
      if (Flags and 9) <> 0 then
        Stream.BreakStroke := True;
    end;
    Stream.Edge := ReadShapeSegment(Stream.Reader, Stream.X, Stream.Y);
  end;

begin
  Advanced := C.Kind = 84;
  C.Bounds := R.Rect;
  C.ShapeBounds := TSWFBounds.FromRect(C.Bounds);
  C.EvenOddFills := True;
  Morph := TSWFMorph.Create;
  C.FMorph := Morph;
  Morph.EndBounds := TSWFBounds.FromRect(R.Rect);
  if Advanced then
  begin
    C.PathBounds := TSWFBounds.FromRect(R.Rect);
    Morph.EndPathBounds := TSWFBounds.FromRect(R.Rect);
    R.U8; // Scaling flags are also stored on the line styles.
  end
  else
  begin
    C.PathBounds := C.ShapeBounds;
    Morph.EndPathBounds := Morph.EndBounds;
  end;
  Boundary := R.U32;
  if (Boundary = 0) or (Boundary >= Cardinal(R.Remaining)) then
    raise ESWFError.Create('Invalid SWF morph end offset');

  StartStream := Default(TMorphStream);
  EndStream := Default(TMorphStream);
  Segments := TList<TSWFMorphSegment>.Create;
  try
    StartStream.Reader := TSWFReader.Create(R.Bytes(Integer(Boundary)), Version);
    EndStream.Reader := R;
    FillCount := ReadShapeStyleCount(StartStream.Reader, True);
    SetLength(C.Fills, FillCount);
    SetLength(Morph.EndFills, FillCount);
    for Index := 0 to FillCount - 1 do
      ReadFillPair(C.Fills[Index], Morph.EndFills[Index]);
    LineCount := ReadShapeStyleCount(StartStream.Reader, True);
    SetLength(C.Fills, FillCount + LineCount);
    SetLength(Morph.EndFills, FillCount + LineCount);
    for Index := FillCount to FillCount + LineCount - 1 do
      ReadLinePair(C.Fills[Index], Morph.EndFills[Index]);

    StartStream.FillBits := StartStream.Reader.Bits(4);
    StartStream.LineBits := StartStream.Reader.Bits(4);
    EndStream.FillBits := R.Bits(4);
    EndStream.LineBits := R.Bits(4);
    repeat
      NextEdge(StartStream);
      NextEdge(EndStream);
      if StartStream.AtEnd <> EndStream.AtEnd then
        raise ESWFError.Create('SWF morph has mismatched edge counts');
      if StartStream.AtEnd then
        Break;
      if Segments.Count >= 1000000 then
        raise ESWFError.Create('SWF morph edge limit');
      Pair.First := StartStream.Edge;
      Pair.Last := EndStream.Edge;
      Pair.Fill0 := ShapeStyleIndex(StartStream.Fill0, 0, FillCount);
      Pair.Fill1 := ShapeStyleIndex(StartStream.Fill1, 0, FillCount);
      Pair.Stroke := ShapeStyleIndex(StartStream.Line, FillCount, LineCount);
      Pair.BreakStroke := StartStream.BreakStroke or EndStream.BreakStroke;
      Segments.Add(Pair);
    until False;
    if (StartStream.Reader.Remaining <> 0) or (EndStream.Reader.Remaining <> 0) then
      raise ESWFError.Create('Invalid SWF morph edge boundary');

    Morph.Segments := Segments.ToArray;
    BuildMorphGeometry(C, Morph.Segments, 0, False);
  finally
    StartStream.Reader.Free;
    Segments.Free;
  end;
end;

end.

