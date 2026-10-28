unit Core.EmulatorRegistry;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections,
  Core.Storage, Core.Emulation, Core.CD.Disc;

type
  TRomFormatInfo = record
    SystemId: string;
    // Empty means native bytes; nonempty IDs belong to platform modules.
    Encoding: string;
  end;

  TRomBytesNormalizer = reference to function(const Data: TBytes): TBytes;
  TRomNormalizer = reference to function(const Data: TBytes; const Format: TRomFormatInfo): TBytes;

  TCoreLoadStage = (Source, Container, Image, Header, OverrideHint);
  TCoreLoadContext = class;
  TCoreMatch = class;
  TCoreRecognizer = reference to function(Context: TCoreLoadContext): TCoreMatch;
  TCoreCreator = reference to function: IEmulationCore;
  TCoreImageCreator = reference to function(const Data: TBytes; Input: TStream): IEmulationCore;
  TArchiveCandidate = reference to function(Context: TCoreLoadContext; const Name: string; Size: UInt64): Boolean;
  TArchiveVariants = reference to function(Context: TCoreLoadContext): Boolean;
  // -1: no preference; 0: retain OldName; 1: prefer NewName.
  TArchivePreference = reference to function(const OldName, NewName: string): Integer;
  TArchiveImageName = reference to function(const Name: string): string;

  TCoreMatch = class
  private
    FCreate: TCoreCreator;
  public
    Id: string;
    Format: TRomFormatInfo;
    ArchiveCandidate: Boolean;
    constructor Create(const CoreId: string; const Creator: TCoreCreator);
    function CreateCore: IEmulationCore;
  end;

  TCoreLoadContext = class
  private
    FStream: TStream;
    FOwnedStream: TStream;
    FStorage: IStorage;
    FRomName, FSourceName: string;
    FData: TBytes;
    FDataLoaded: Boolean;
    FDisc: TCDDisc;
    FDiscChecked, FDiscSource: Boolean;
    FConvertedArchive, FArchiveEntry: Boolean;
    FHeaderRecognized: Boolean;
    function GetData: TBytes;
    function GetEffectiveStorage: IStorage;
    function GetDisc: TCDDisc;
  public
    HeaderFormat: TRomFormatInfo;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string;
      const ImageName: string = ''; IsArchiveEntry: Boolean = False);
    destructor Destroy; override;
    procedure PrepareArchive;
    procedure LoadArchiveEntry(const Bytes: TBytes; const Name: string);
    function HasExtension(const Extensions: array of string): Boolean;
    function Signature(Offset: Integer; const Text: AnsiString): Boolean;
    function Prefix(Size: Integer): TBytes;
    function IsDiscSource: Boolean;
    function DiscSector(Offset: Integer): TBytes;
    function DiscSignature(const Text: string; Offset: Integer = 0): Boolean;
    function TakeDisc: TCDDisc;
    function FirstPlaylistEntry: string;
    property Stream: TStream read FStream;
    property Storage: IStorage read FStorage;
    property EffectiveStorage: IStorage read GetEffectiveStorage;
    property RomName: string read FRomName;
    property SourceName: string read FSourceName;
    property Data: TBytes read GetData;
    property Disc: TCDDisc read GetDisc;
    property ConvertedArchive: Boolean read FConvertedArchive;
    property ArchiveEntry: Boolean read FArchiveEntry;
    property HeaderRecognized: Boolean read FHeaderRecognized;
  end;

  TCoreRecognitionRule = record
    Stage: TCoreLoadStage;
    Priority: Integer;
    Recognize: TCoreRecognizer;
  end;

  TEmulationCoreRegistration = class
  private
    FRules: TList<TCoreRecognitionRule>;
  public
    Id: string;
    ArchiveExtensions: TArray<string>;
    ExtraArchiveCandidate: TArchiveCandidate;
    AllowArchiveVariants: TArchiveVariants;
    ArchivePreference: TArchivePreference;
    ArchiveImageName: TArchiveImageName;
    constructor Create(const CoreId: string; const Extensions: array of string);
    destructor Destroy; override;
    procedure Add(Stage: TCoreLoadStage; Priority: Integer; const Recognizer: TCoreRecognizer);
  end;

// Registration is static, in initialization sections. The registry owns it.
procedure RegisterEmulationCore(Registration: TEmulationCoreRegistration);
function RegisteredEmulationCores: TArray<string>;
function RecognizeEmulationCore(Context: TCoreLoadContext; Stage: TCoreLoadStage): TCoreMatch;
function ResolveEmulationImage(Context: TCoreLoadContext): TCoreMatch;
// The caller owns the returned match and must keep Context alive through CreateCore.
function ResolveEmulationCore(Context: TCoreLoadContext): TCoreMatch;
procedure SelectArchiveImage(Context: TCoreLoadContext);
procedure RegisterRomEncoding(const Encoding: string; const Normalizer: TRomBytesNormalizer);
procedure RegisterRomNormalizer(const SystemId: string; const Normalizer: TRomNormalizer);

function ImageMatch(Context: TCoreLoadContext; const Id: string;
  const Creator: TCoreImageCreator; Normalize: Boolean = False;
  const SystemId: string = ''; const Encoding: string = '';
  SizeLimit: Int64 = 64 * 1024 * 1024): TCoreMatch;

implementation

uses System.StrUtils, System.Zip, System.Generics.Defaults, Core.MediaArchive,
  Core.ArchiveStorage;

const
  MAX_ARCHIVE_IMAGE_SIZE = 64 * 1024 * 1024;

var
  Registrations: TObjectList<TEmulationCoreRegistration>;
  Normalizers: TDictionary<string, TRomNormalizer>;
  EncodingNormalizers: TDictionary<string, TRomBytesNormalizer>;

function CartridgeVariantScore(const Name: string): Integer;
begin
  var S := Name.ToLower;
  Result := 0;
  if S.Contains('[!]') then
    Inc(Result, 30);
  if S.Contains('(world)') or S.Contains('(europe)') or S.Contains('(usa)') or
    S.Contains('(ue)') or S.Contains('(u)') or S.Contains('(e)') or S.Contains('(jue)') or S.Contains('(en') then
    Inc(Result, 20);
  if S.Contains('[a') or S.Contains('[b') or S.Contains('[h') or S.Contains('[o') or
    S.Contains('[t') or S.Contains('(beta') or S.Contains('(proto') or
    S.Contains('(demo') then
    Dec(Result, 100);
end;

procedure RegisterRomEncoding(const Encoding: string; const Normalizer: TRomBytesNormalizer);
begin
  if (Encoding.Trim = '') or not Assigned(Normalizer) then
    raise EArgumentException.Create('Invalid ROM encoding');
  EncodingNormalizers.Add(Encoding.Trim, Normalizer);
end;

procedure RegisterRomNormalizer(const SystemId: string; const Normalizer: TRomNormalizer);
begin
  if (SystemId.Trim = '') or not Assigned(Normalizer) then
    raise EArgumentException.Create('Invalid ROM normalizer');
  Normalizers.Add(SystemId.Trim, Normalizer);
end;

function NormalizeRomBytes(const Data: TBytes; const Encoding: string): TBytes;
begin
  if Encoding = '' then
    Exit(Copy(Data));
  var Normalizer: TRomBytesNormalizer;
  if not EncodingNormalizers.TryGetValue(Encoding, Normalizer) then
    raise EReadError.Create('No normalizer registered for this ROM encoding');
  Result := Normalizer(Data);
end;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;
begin
  var Normalizer: TRomNormalizer;
  if Normalizers.TryGetValue(Format.SystemId, Normalizer) then
    Exit(Normalizer(Data, Format));
  Result := NormalizeRomBytes(Data, Format.Encoding);
end;

constructor TCoreMatch.Create(const CoreId: string; const Creator: TCoreCreator);
begin
  inherited Create;
  Id := CoreId;
  FCreate := Creator;
  ArchiveCandidate := True;
end;

function TCoreMatch.CreateCore: IEmulationCore;
begin
  Result := FCreate();
end;

function ImageMatch(Context: TCoreLoadContext; const Id: string;
  const Creator: TCoreImageCreator; Normalize: Boolean; const SystemId: string;
  const Encoding: string; SizeLimit: Int64): TCoreMatch;
begin
  var Format: TRomFormatInfo;
  Format.SystemId := SystemId.Trim.ToLower;
  Format.Encoding := Encoding;
  Result := TCoreMatch.Create(Id,
    function: IEmulationCore
    begin
      var Bytes := Context.Data;
      if (SizeLimit > 0) and (Length(Bytes) > SizeLimit) then
        raise EReadError.Create('ROM exceeds 64 MiB');
      if Normalize then Bytes := NormalizeRom(Bytes, Format);
      var Input := TBytesStream.Create(Bytes);
      try
        Result := Creator(Bytes, Input);
      finally
        Input.Free;
      end;
    end);
  Result.Format := Format;
end;

constructor TCoreLoadContext.Create(Stream: TStream; const Storage: IStorage;
  const RomName, ImageName: string; IsArchiveEntry: Boolean);
begin
  inherited Create;
  if Stream = nil then raise EArgumentNilException.Create('Stream');
  FStream := Stream;
  FStorage := Storage;
  FRomName := RomName;
  FArchiveEntry := IsArchiveEntry;
  FSourceName := ImageName;
  if FSourceName = '' then
  begin
    FSourceName := RomName;
    if (Storage <> nil) and RomName.StartsWith('content://', True) then
      FSourceName := Storage.Describe(RomName).Name;
  end;
end;

destructor TCoreLoadContext.Destroy;
begin
  FDisc.Free;
  FOwnedStream.Free;
  inherited;
end;

function TCoreLoadContext.GetEffectiveStorage: IStorage;
begin
  Result := FStorage;
  if Result = nil then Result := TStorage.Default;
end;

function TCoreLoadContext.GetData: TBytes;
begin
  if not FDataLoaded then
  begin
    FData := ReadMediaContainer(FStream);
    FDataLoaded := True;
  end;
  Result := FData;
end;

procedure TCoreLoadContext.PrepareArchive;
begin
  if not IsMediaArchive(FSourceName) or HasExtension(['.zip']) then Exit;
  var Bytes := DecodeMediaArchive(FSourceName, Data);
  FConvertedArchive := True;
  FSourceName := ChangeFileExt(FSourceName, '.zip');
  // Cores may reopen media after the factory returns (e.g. CD workers).
  // Retain canonical data through their storage reference, with original paths.
  FStorage := ArchiveStorage(EffectiveStorage, FRomName, FSourceName, Bytes);
  FOwnedStream := TBytesStream.Create(Bytes);
  FStream := FOwnedStream;
  FData := Bytes;
  FDataLoaded := True;
end;

procedure TCoreLoadContext.LoadArchiveEntry(const Bytes: TBytes; const Name: string);
begin
  FreeAndNil(FDisc);
  FDiscChecked := False;
  FreeAndNil(FOwnedStream);
  FOwnedStream := TBytesStream.Create(Bytes);
  FStream := FOwnedStream;
  FData := Bytes;
  FDataLoaded := True;
  FSourceName := Name;
  FArchiveEntry := True;
end;

function TCoreLoadContext.HasExtension(const Extensions: array of string): Boolean;
begin
  Result := MatchText(ExtractFileExt(FSourceName), Extensions);
end;

function TCoreLoadContext.Signature(Offset: Integer; const Text: AnsiString): Boolean;
begin
  var Bytes := Data;
  Result := (Offset >= 0) and (Length(Text) > 0) and (Offset <= Length(Bytes) - Length(Text)) and
    CompareMem(@Bytes[Offset], PAnsiChar(Text), Length(Text));
end;

function TCoreLoadContext.Prefix(Size: Integer): TBytes;
begin
  if Size < 0 then raise EArgumentOutOfRangeException.Create('Prefix size');
  var Saved := FStream.Position;
  try
    SetLength(Result, Size);
    var Count := 0;
    while Count < Size do
    begin
      var Read := FStream.Read(Result[Count], Size - Count);
      if Read = 0 then Break;
      if Read < 0 then raise EReadError.Create('Invalid stream read count');
      Inc(Count, Read);
    end;
    SetLength(Result, Count);
  finally
    FStream.Position := Saved;
  end;
end;

function TCoreLoadContext.IsDiscSource: Boolean;
begin
  if not FDiscChecked then
  begin
    FDiscChecked := True;
    FDiscSource := not FArchiveEntry and IsCDMediaSource(FSourceName, FStream);
  end;
  Result := FDiscSource;
end;

function TCoreLoadContext.GetDisc: TCDDisc;
begin
  if FDisc = nil then FDisc := TCDDisc.Create(FStream, EffectiveStorage, FRomName, False, FSourceName);
  Result := FDisc;
end;

function TCoreLoadContext.TakeDisc: TCDDisc;
begin
  Result := Disc;
  FDisc := nil;
end;

function TCoreLoadContext.DiscSector(Offset: Integer): TBytes;
begin
  Result := nil;
  for var T := 1 to Disc.TrackCount do
  begin
    var Track := Disc.Track(T);
    if Track.Audio then Continue;
    if Disc.IsData(Track.StartLBA + Offset) then Disc.ReadData(Track.StartLBA + Offset, Result);
    Break;
  end;
end;

function TCoreLoadContext.DiscSignature(const Text: string; Offset: Integer): Boolean;
begin
  var Sector := DiscSector(Offset);
  Result := (Length(Sector) >= Length(Text)) and
    (TEncoding.ASCII.GetString(Sector, 0, Length(Text)) = Text);
end;

function TCoreLoadContext.FirstPlaylistEntry: string;
begin
  Result := '';
  for var Line in TEncoding.UTF8.GetString(Prefix(64 * 1024)).Split([#13, #10]) do
  begin
    var Entry := Line.Trim;
    if (Entry <> '') and not Entry.StartsWith('#') then Exit(Entry.DeQuotedString('"'));
  end;
end;

constructor TEmulationCoreRegistration.Create(const CoreId: string; const Extensions: array of string);
begin
  inherited Create;
  Id := CoreId;
  FRules := TList<TCoreRecognitionRule>.Create;
  SetLength(ArchiveExtensions, Length(Extensions));
  for var I := 0 to High(Extensions) do ArchiveExtensions[I] := Extensions[I];
end;

destructor TEmulationCoreRegistration.Destroy;
begin
  FRules.Free;
  inherited;
end;

procedure TEmulationCoreRegistration.Add(Stage: TCoreLoadStage; Priority: Integer; const Recognizer: TCoreRecognizer);
begin
  if not Assigned(Recognizer) then raise EArgumentNilException.Create('Recognizer');
  var Rule: TCoreRecognitionRule;
  Rule.Stage := Stage;
  Rule.Priority := Priority;
  Rule.Recognize := Recognizer;
  FRules.Add(Rule);
end;

procedure RegisterEmulationCore(Registration: TEmulationCoreRegistration);
begin
  if Registration = nil then raise EArgumentNilException.Create('Registration');
  try
    if Registration.Id = '' then raise EArgumentException.Create('Empty core registration ID');
    for var Existing in Registrations do
      if SameText(Existing.Id, Registration.Id) then
        raise EArgumentException.Create('Duplicate core registration: ' + Registration.Id);
    Registrations.Add(Registration);
  except
    Registration.Free;
    raise;
  end;
end;

function RegisteredEmulationCores: TArray<string>;
begin
  SetLength(Result, Registrations.Count);
  for var I := 0 to Registrations.Count - 1 do Result[I] := Registrations[I].Id;
end;

function RecognizeEmulationCore(Context: TCoreLoadContext; Stage: TCoreLoadStage): TCoreMatch;
begin
  Result := nil;
  // Explicit priority and ID tie-breaking make dependency initialization order irrelevant.
  var Rules := TList<TPair<string, TCoreRecognitionRule>>.Create;
  try
    for var Registration in Registrations do
      for var Rule in Registration.FRules do
        if Rule.Stage = Stage then Rules.Add(TPair<string, TCoreRecognitionRule>.Create(Registration.Id, Rule));
    Rules.Sort(TComparer<TPair<string, TCoreRecognitionRule>>.Construct(
      function(const Left, Right: TPair<string, TCoreRecognitionRule>): Integer
      begin
        Result := 0;
        if Left.Value.Priority < Right.Value.Priority then Result := -1;
        if Left.Value.Priority > Right.Value.Priority then Result := 1;
        if Result = 0 then Result := CompareText(Left.Key, Right.Key);
      end));
    for var Rule in Rules do
    begin
      var Saved := Context.Stream.Position;
      try
        Result := Rule.Value.Recognize(Context);
      finally
        // Loading the lazy byte view consumes the stream, as before; a probe
        // must not change the start position seen by subsequent recognizers.
        Context.Stream.Position := Saved;
      end;
      if Result <> nil then Exit;
    end;
  finally
    Rules.Free;
  end;
end;

function ResolveEmulationImage(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := RecognizeEmulationCore(Context, TCoreLoadStage.Image);
  if Result <> nil then Exit;
  Result := RecognizeEmulationCore(Context, TCoreLoadStage.Header);
  Context.FHeaderRecognized := Result <> nil;
  Context.HeaderFormat := Default(TRomFormatInfo);
  if Result <> nil then Context.HeaderFormat := Result.Format;
  try
    var Override := RecognizeEmulationCore(Context, TCoreLoadStage.OverrideHint);
    if Override <> nil then
    begin
      Result.Free;
      Result := Override;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ResolveEmulationCore(Context: TCoreLoadContext): TCoreMatch;
begin
  Context.PrepareArchive;
  Result := RecognizeEmulationCore(Context, TCoreLoadStage.Source);
  if Result = nil then Result := RecognizeEmulationCore(Context, TCoreLoadStage.Container);
  if Result = nil then
  begin
    SelectArchiveImage(Context);
    if Context.ArchiveEntry then Result := RecognizeEmulationCore(Context, TCoreLoadStage.Source);
    if Result = nil then Result := ResolveEmulationImage(Context);
  end;
end;

procedure SelectArchiveImage(Context: TCoreLoadContext);
begin
  if not Context.HasExtension(['.zip']) then Exit;
  var Archive := TZipFile.Create;
  var Saved := Context.Stream.Position;
  try
    Archive.Open(Context.Stream, zmRead);
    var Candidate := -1;
    var AllowVariants := Context.ConvertedArchive;
    for var Registration in Registrations do
      if Assigned(Registration.AllowArchiveVariants) and Registration.AllowArchiveVariants(Context) then
        AllowVariants := True;
    for var I := 0 to Archive.FileCount - 1 do
    begin
      TStorage.CheckReadCancelled;
      var Name := Archive.FileNames[I];
      if Name.Contains('__MACOSX/') or ExtractFileName(Name).StartsWith('._') or
        Name.EndsWith('/') or Name.EndsWith('\') then Continue;
      var Size := Archive.FileInfo[I].UncompressedSize64;
      var Suitable := False;
      for var Registration in Registrations do
      begin
        Suitable := MatchText(ExtractFileExt(Name), Registration.ArchiveExtensions) or
          (Assigned(Registration.ExtraArchiveCandidate) and Registration.ExtraArchiveCandidate(Context, Name, Size));
        if Suitable then Break;
      end;
      // No global extension whitelist: every registered image recognizer also
      // sees unknown entry names, so content detection also works in ZIPs.
      if not Suitable and (Size <= MAX_ARCHIVE_IMAGE_SIZE) then
      begin
        var Bytes: TBytes;
        Archive.Read(I, Bytes);
        var Input := TBytesStream.Create(Bytes);
        try
          var Probe := TCoreLoadContext.Create(Input, Context.Storage, Context.RomName, Name, True);
          try
            var Match := RecognizeEmulationCore(Probe, TCoreLoadStage.Source);
            if Match = nil then Match := RecognizeEmulationCore(Probe, TCoreLoadStage.Container);
            if Match = nil then Match := ResolveEmulationImage(Probe);
            try
              Suitable := (Match <> nil) and Match.ArchiveCandidate;
            finally
              Match.Free;
            end;
          finally
            Probe.Free;
          end;
        finally
          Input.Free;
        end;
      end;
      if not Suitable then Continue;
      if Candidate >= 0 then
      begin
        var OldName := Archive.FileNames[Candidate];
        if not AllowVariants then
        begin
          var Preference := -1;
          for var Registration in Registrations do
            if Assigned(Registration.ArchivePreference) then
            begin
              Preference := Registration.ArchivePreference(OldName, Name);
              if Preference >= 0 then Break;
            end;
          if Preference = 0 then Continue;
          if Preference < 0 then raise EReadError.Create('Cartridge ZIP must contain one cartridge or disk image');
        end
        else
        begin
          var Score := CartridgeVariantScore(Name);
          var Previous := CartridgeVariantScore(OldName);
          if (Score < Previous) or ((Score = Previous) and (CompareText(Name, OldName) >= 0)) then Continue;
        end;
      end;
      Candidate := I;
    end;
    if Candidate >= 0 then
    begin
      if Archive.FileInfo[Candidate].UncompressedSize64 > MAX_ARCHIVE_IMAGE_SIZE then
        raise EReadError.Create('Cartridge archive image exceeds 64 MiB');
      var Name := Archive.FileNames[Candidate];
      for var Registration in Registrations do
        if Assigned(Registration.ArchiveImageName) then Name := Registration.ArchiveImageName(Name);
      var Bytes: TBytes;
      Archive.Read(Candidate, Bytes);
      // Close the archive before replacing its backing stream.
      Archive.Close;
      Context.LoadArchiveEntry(Bytes, Name);
      Exit;
    end;
  finally
    Archive.Free;
    if not Context.ArchiveEntry then Context.Stream.Position := Saved;
  end;
end;

initialization
  Normalizers := TDictionary<string, TRomNormalizer>.Create(TIStringComparer.Ordinal);
  EncodingNormalizers := TDictionary<string, TRomBytesNormalizer>.Create(TIStringComparer.Ordinal);
  Registrations := TObjectList<TEmulationCoreRegistration>.Create(True);
finalization
  Normalizers.Free;
  EncodingNormalizers.Free;
  Registrations.Free;
end.
