unit Core.EmulatorRegistry;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, Core.Storage,
  Core.Emulation, Core.CD.Disc, Core.Archive.Container;

type
  TRomFormatInfo = record
    SystemId: string;
    // Empty means native bytes; nonempty IDs belong to platform modules.
    Encoding: string;
  end;

  TRomBytesNormalizer = reference to function(const Data: TBytes): TBytes;

  TRomNormalizer = reference to function(const Data: TBytes; const Format: TRomFormatInfo): TBytes;

  TCoreLoadStage = (Source, Container, Image, Header, OverrideHint);

  TCoreMatchConfidence = (Fallback, Hint, Signature);

  TCorePlatformOption = record
    Id, Name: string;
  end;

  ECoreSelectionRequired = class(EReadError)
  private
    FPlatforms: TArray<TCorePlatformOption>;
    FFailedPlatformId, FLoadError: string;
  public
    constructor Create(const Platforms: TArray<TCorePlatformOption>; const FailedPlatformId: string = ''; const LoadError: string = '');
    property Platforms: TArray<TCorePlatformOption> read FPlatforms;
    property FailedPlatformId: string read FFailedPlatformId;
    property LoadError: string read FLoadError;
  end;

  TCoreLoadContext = class;

  TCoreMatch = class;

  TCoreRecognizer = reference to function(Context: TCoreLoadContext): TCoreMatch;

  TCoreCreator = reference to function: IEmulationCore;

  TCoreImageCreator = reference to function(const Data: TBytes; Input: TStream): IEmulationCore;

  TArchiveCandidate = reference to function(Context: TCoreLoadContext; const Name: string; Size: UInt64): Boolean;

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
    Confidence: TCoreMatchConfidence;
    function PlatformId: string;
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
    FSourceHash: TBytes;
    FDataLoaded: Boolean;
    FDisc: TCDDisc;
    FDiscChecked, FDiscSource: Boolean;
    FArchive: IArchiveContainer;
    FArchiveEntry: Boolean;
    FHeaderRecognized: Boolean;
    FSelectedPlatform, FExcludedPlatform: string;
    function GetData: TBytes;
    function GetSourceHash: TBytes;
    function GetEffectiveStorage: IStorage;
    function GetDisc: TCDDisc;
  public
    HeaderFormat: TRomFormatInfo;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string = ''; IsArchiveEntry: Boolean = False);
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
    function PlaylistDisc(const SystemId: string): TCDDisc;
    property Stream: TStream read FStream;
    property Storage: IStorage read FStorage;
    property EffectiveStorage: IStorage read GetEffectiveStorage;
    property RomName: string read FRomName;
    property SourceName: string read FSourceName;
    property SourceHash: TBytes read GetSourceHash;
    property Data: TBytes read GetData;
    property Disc: TCDDisc read GetDisc;
    property Archive: IArchiveContainer read FArchive;
    property ArchiveEntry: Boolean read FArchiveEntry;
    property HeaderRecognized: Boolean read FHeaderRecognized;
    property SelectedPlatform: string read FSelectedPlatform;
  end;

  TCoreRecognitionRule = record
    Stage: TCoreLoadStage;
    Priority: Integer;
    Recognize: TCoreRecognizer;
  end;

  TCoreDiscPlatform = record
    PlatformId: string;
    Match: TCoreRecognizer;
  end;

  TEmulationCoreRegistration = class
  private
    FRules: TList<TCoreRecognitionRule>;
    FDiscPlatforms: TList<TCoreDiscPlatform>;
  public
    Id: string;
    ArchiveExtensions: TArray<string>;
    ExtraArchiveCandidate: TArchiveCandidate;
    ArchivePreference: TArchivePreference;
    ArchiveImageName: TArchiveImageName;
    MaxArchiveImageSize: Int64;
    constructor Create(const CoreId: string; const Extensions: array of string);
    destructor Destroy; override;
    procedure Add(Stage: TCoreLoadStage; Priority: Integer; const Recognizer: TCoreRecognizer);
    procedure AddDiscPlatform(const PlatformId: string; const Match: TCoreRecognizer);
  end;

// Registration is static, in initialization sections. The registry owns it.
procedure RegisterEmulationCore(Registration: TEmulationCoreRegistration);

function RegisteredEmulationCores: TArray<string>;

function RecognizeEmulationCore(Context: TCoreLoadContext; Stage: TCoreLoadStage): TCoreMatch;

function ResolveEmulationImage(Context: TCoreLoadContext): TCoreMatch;
// The caller owns the returned match and must keep Context alive through CreateCore.

function ResolveEmulationCore(Context: TCoreLoadContext; const PlatformId: string = ''; const ExcludedPlatformId: string = ''): TCoreMatch;

// Enumerates compatible targets without constructing an emulator.
function EmulationPlatformOptions(Context: TCoreLoadContext): TArray<TCorePlatformOption>;

procedure SelectArchiveImage(Context: TCoreLoadContext);

procedure RegisterRomEncoding(const Encoding: string; const Normalizer: TRomBytesNormalizer);

procedure RegisterRomNormalizer(const SystemId: string; const Normalizer: TRomNormalizer);

function ImageMatch(Context: TCoreLoadContext; const Id: string; const Creator: TCoreImageCreator; Normalize: Boolean = False; const SystemId: string = ''; const Encoding: string = ''; SizeLimit: Int64 = 64 * 1024 * 1024): TCoreMatch;

implementation

uses
  System.StrUtils, System.Hash, System.Math, System.Generics.Defaults,
  Core.MediaArchive, Core.Platforms;

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
  Confidence := TCoreMatchConfidence.Signature;
end;

constructor ECoreSelectionRequired.Create(const Platforms: TArray<TCorePlatformOption>; const FailedPlatformId, LoadError: string);
begin
  FPlatforms := Copy(Platforms);
  FFailedPlatformId := FailedPlatformId;
  FLoadError := LoadError;
  var Names: TArray<string>;
  SetLength(Names, Length(Platforms));
  for var I := 0 to High(Platforms) do
    Names[I] := Platforms[I].Name;
  var Detail := 'Choose a target platform: ' + string.Join(', ', Names);
  if LoadError <> '' then
    Detail := LoadError + sLineBreak + Detail;
  inherited Create(Detail);
end;

function TCoreMatch.PlatformId: string;
begin
  Result := Format.SystemId;
  if Result = '' then
    Result := Id.ToLower;
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Result, Info) then
    Result := Info.Id;
end;

function TCoreMatch.CreateCore: IEmulationCore;
begin
  Result := FCreate();
end;

function ImageMatch(Context: TCoreLoadContext; const Id: string; const Creator: TCoreImageCreator; Normalize: Boolean; const SystemId: string; const Encoding: string; SizeLimit: Int64): TCoreMatch;
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
      if Normalize then
        Bytes := NormalizeRom(Bytes, Format);
      var Input := TBytesStream.Create(Bytes);
      try
        Result := Creator(Bytes, Input);
      finally
        Input.Free;
      end;
    end);
  Result.Format := Format;
end;

constructor TCoreLoadContext.Create(Stream: TStream; const Storage: IStorage; const RomName, ImageName: string; IsArchiveEntry: Boolean);
begin
  inherited Create;
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
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
  if Result = nil then
    Result := TStorage.Default;
end;

function TCoreLoadContext.GetSourceHash: TBytes;
begin
  if Length(FSourceHash) = 0 then
  begin
    var Saved := FStream.Position;
    var Hash := THashSHA2.Create;
    var Failed := False;
    try
      try
        FStream.Position := 0;
        var Buffer: array[0..65535] of Byte;
        while True do
        begin
          TStorage.CheckReadCancelled;
          var N := FStream.Read(Buffer, SizeOf(Buffer));
          if N = 0 then
            Break;
          if (N < 0) or (N > SizeOf(Buffer)) then
            raise EReadError.Create('Invalid source hash read');
          Hash.Update(Buffer, N);
        end;
      except
        Failed := True;
        raise;
      end;
    finally
      try
        FStream.Position := Saved;
      except
        if not Failed then
          raise;
      end;
    end;
    FSourceHash := Hash.HashAsBytes;
  end;
  Result := Copy(FSourceHash);
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
  if FArchiveEntry or (FArchive <> nil) or not IsMediaArchive(FSourceName) then
    Exit;
  FArchive := OpenMediaArchive(FStream, FSourceName, EffectiveStorage);
  FOwnedStream := TArchiveSourceStream.Create(FStream, FArchive);
  FStream := FOwnedStream;
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
  FSourceHash := nil;
  FArchive := nil;
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
  if Size < 0 then
    raise EArgumentOutOfRangeException.Create('Prefix size');
  var Saved := FStream.Position;
  try
    SetLength(Result, Size);
    var Count := 0;
    while Count < Size do
    begin
      var Read := FStream.Read(Result[Count], Size - Count);
      if Read = 0 then
        Break;
      if Read < 0 then
        raise EReadError.Create('Invalid stream read count');
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
  if FDisc = nil then
    FDisc := TCDDisc.Create(FStream, EffectiveStorage, FRomName, False, FSourceName);
  Result := FDisc;
end;

function TCoreLoadContext.TakeDisc: TCDDisc;
begin
  if HasExtension(['.m3u']) then
    Exit(nil);
  Result := Disc;
  FDisc := nil;
end;

function TCoreLoadContext.DiscSector(Offset: Integer): TBytes;
begin
  Result := nil;
  for var T := 1 to Disc.TrackCount do
  begin
    var Track := Disc.Track(T);
    if Track.Audio then
      Continue;
    if Disc.IsData(Track.StartLBA + Offset) then
      Disc.ReadData(Track.StartLBA + Offset, Result);
    Break;
  end;
end;

function TCoreLoadContext.DiscSignature(const Text: string; Offset: Integer): Boolean;
begin
  var Sector := DiscSector(Offset);
  Result := (Length(Sector) >= Length(Text)) and (TEncoding.ASCII.GetString(Sector, 0, Length(Text)) = Text);
end;

function TCoreLoadContext.PlaylistDisc(const SystemId: string): TCDDisc;
begin
  if FDisc = nil then
  begin
    var Position := Stream.Position;
    var Names: TArray<string>;
    try
      Names := ReadCDPlaylist(Stream, EffectiveStorage, RomName, SystemId);
    finally
      Stream.Position := Position;
    end;
    var Input := EffectiveStorage.OpenRead(Names[0]);
    try
      FDisc := TCDDisc.Create(Input, EffectiveStorage, Names[0], True);
    finally
      Input.Free;
    end;
  end;
  Result := FDisc;
end;

function TCoreLoadContext.FirstPlaylistEntry: string;
begin
  Result := '';
  for var Line in TEncoding.UTF8.GetString(Prefix(64 * 1024)).Split([#13, #10]) do
  begin
    var Entry := Line.Trim;
    if (Entry <> '') and not Entry.StartsWith('#') then
      Exit(Entry.DeQuotedString('"'));
  end;
end;

constructor TEmulationCoreRegistration.Create(const CoreId: string; const Extensions: array of string);
begin
  inherited Create;
  Id := CoreId;
  MaxArchiveImageSize := MAX_ARCHIVE_IMAGE_SIZE;
  FRules := TList<TCoreRecognitionRule>.Create;
  FDiscPlatforms := TList<TCoreDiscPlatform>.Create;
  SetLength(ArchiveExtensions, Length(Extensions));
  for var i := 0 to High(Extensions) do
    ArchiveExtensions[i] := Extensions[i];
end;

destructor TEmulationCoreRegistration.Destroy;
begin
  FDiscPlatforms.Free;
  FRules.Free;
  inherited;
end;

procedure TEmulationCoreRegistration.Add(Stage: TCoreLoadStage; Priority: Integer; const Recognizer: TCoreRecognizer);
begin
  if not Assigned(Recognizer) then
    raise EArgumentNilException.Create('Recognizer');
  var Rule: TCoreRecognitionRule;
  Rule.Stage := Stage;
  Rule.Priority := Priority;
  Rule.Recognize := Recognizer;
  FRules.Add(Rule);
end;

procedure TEmulationCoreRegistration.AddDiscPlatform(const PlatformId: string; const Match: TCoreRecognizer);
begin
  if (PlatformId = '') or not Assigned(Match) then
    raise EArgumentException.Create('Invalid disc platform loader');
  var Item: TCoreDiscPlatform;
  Item.PlatformId := PlatformId;
  Item.Match := Match;
  FDiscPlatforms.Add(Item);
end;

procedure RegisterEmulationCore(Registration: TEmulationCoreRegistration);
begin
  if Registration = nil then
    raise EArgumentNilException.Create('Registration');
  try
    if Registration.Id = '' then
      raise EArgumentException.Create('Empty core registration ID');
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
  for var i := 0 to Registrations.Count - 1 do
    Result[i] := Registrations[i].Id;
end;

function ProbeCore(Context: TCoreLoadContext; const Recognizer: TCoreRecognizer): TCoreMatch;
begin
  try
    Result := Recognizer(Context);
  except
    on E: EAbort do
      raise;
    on E: Exception do
    begin
      // A failed library attempt must not let one recognizer prevent the
      // fallback search from considering other platforms. Explicit loads
      // and ordinary auto-detection retain their original error reporting.
      if Context.FExcludedPlatform = '' then
        raise;
      Result := nil;
    end;
  end;
end;

function RecognizeEmulationCore(Context: TCoreLoadContext; Stage: TCoreLoadStage): TCoreMatch;
begin
  Result := nil;
  // Explicit priority and ID tie-breaking make dependency initialization order irrelevant.
  var Rules := TList<TPair<string, TCoreRecognitionRule>>.Create;
  try
    for var Registration in Registrations do
      for var Rule in Registration.FRules do
        if Rule.Stage = Stage then
          Rules.Add(TPair<string, TCoreRecognitionRule>.Create(Registration.Id, Rule));
    Rules.Sort(TComparer<TPair<string, TCoreRecognitionRule>>.Construct(
      function(const Left, Right: TPair<string, TCoreRecognitionRule>): Integer
      begin
        Result := 0;
        if Left.Value.Priority < Right.Value.Priority then
          Result := -1;
        if Left.Value.Priority > Right.Value.Priority then
          Result := 1;
        if Result = 0 then
          Result := CompareText(Left.Key, Right.Key);
      end));
    for var Rule in Rules do
    begin
      var Saved := Context.Stream.Position;
      try
        Result := ProbeCore(Context, Rule.Value.Recognize);
      finally
        // Loading the lazy byte view consumes the stream, as before; a probe
        // must not change the start position seen by subsequent recognizers.
        Context.Stream.Position := Saved;
      end;
      if (Result <> nil) and (Context.FExcludedPlatform <> '') and
        SameText(Result.PlatformId, Context.FExcludedPlatform) then
        FreeAndNil(Result);
      if Result <> nil then
        Exit;
    end;
  finally
    Rules.Free;
  end;
end;

function AcceptsSelectedPlatform(Context: TCoreLoadContext; Match: TCoreMatch): Boolean;
begin
  if (Context.FExcludedPlatform <> '') and SameText(Context.FExcludedPlatform, Match.PlatformId) then
    Exit(False);
  Result := (Context.SelectedPlatform = '') or SameText(Context.SelectedPlatform, Match.PlatformId);
  if Result then
    Exit;
  // Some adapters determine a machine variant from the cartridge itself
  // (32X, SuperGrafx, WonderSwan Color). A category can select that same core.
  var Info: TPlatformInfo;
  Result := not Context.IsDiscSource and not Context.HasExtension(['.m3u']) and
    TPlatformRegistry.Find(Context.SelectedPlatform, Info) and
    SameText(Info.CoreId, Match.Id) and Context.HasExtension(Info.Extensions);
end;

function ChooseCoreMatch(Context: TCoreLoadContext; Matches: TObjectList<TCoreMatch>; Minimum: TCoreMatchConfidence = TCoreMatchConfidence.Fallback): TCoreMatch;
begin
  Result := nil;
  var Best := Minimum;
  var Choices := TList<TCoreMatch>.Create;
  try
    for var Match in Matches do
    begin
      if not AcceptsSelectedPlatform(Context, Match) then
        Continue;
      if Match.Confidence < Best then
        Continue;
      if Match.Confidence > Best then
      begin
        Choices.Clear;
        Best := Match.Confidence;
      end;
      var Duplicate := False;
      for var Existing in Choices do
        Duplicate := Duplicate or SameText(Existing.PlatformId, Match.PlatformId);
      if not Duplicate then
        Choices.Add(Match);
    end;
    if Choices.Count > 1 then
    begin
      var Platforms: TArray<TCorePlatformOption>;
      SetLength(Platforms, Choices.Count);
      for var I := 0 to Choices.Count - 1 do
      begin
        Platforms[I].Id := Choices[I].PlatformId;
        var Info: TPlatformInfo;
        if TPlatformRegistry.Find(Platforms[I].Id, Info) then
          Platforms[I].Name := Info.Name
        else
          Platforms[I].Name := Choices[I].Id;
      end;
      TArray.Sort<TCorePlatformOption>(Platforms, TComparer<TCorePlatformOption>.Construct(
        function(const Left, Right: TCorePlatformOption): Integer
        begin
          Result := CompareText(Left.Name, Right.Name);
        end));
      raise ECoreSelectionRequired.Create(Platforms);
    end;
    if Choices.Count = 1 then
      Result := Matches.Extract(Choices[0]);
  finally
    Choices.Free;
  end;
end;

function CollectCoreMatches(Context: TCoreLoadContext; Stage: TCoreLoadStage): TObjectList<TCoreMatch>;
begin
  Result := TObjectList<TCoreMatch>.Create(True);
  try
    // Container rules can replace the stream and retain their original resolver.
    // Source/image/header probes are non-owning and must all report evidence.
    for var Registration in Registrations do
      for var Rule in Registration.FRules do
        if Rule.Stage = Stage then
        begin
          TStorage.CheckReadCancelled;
          var Saved := Context.Stream.Position;
          try
            var Match := ProbeCore(Context, Rule.Recognize);
            if Match <> nil then
              Result.Add(Match);
          finally
            Context.Stream.Position := Saved;
          end;
        end;
  except
    Result.Free;
    raise;
  end;
end;

function SelectRecognizedCore(Context: TCoreLoadContext; Stage: TCoreLoadStage; Minimum: TCoreMatchConfidence = TCoreMatchConfidence.Fallback): TCoreMatch;
begin
  var Matches := CollectCoreMatches(Context, Stage);
  try
    Result := ChooseCoreMatch(Context, Matches, Minimum);
  finally
    Matches.Free;
  end;
end;

function SelectDiscPlatform(Context: TCoreLoadContext): TCoreMatch;
begin
  var Matches := TObjectList<TCoreMatch>.Create(True);
  try
    var Hint := ('/' + Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
    for var Registration in Registrations do
      for var Loader in Registration.FDiscPlatforms do
      begin
        var Info := TPlatformRegistry.Require(Loader.PlatformId);
        if SameText(Info.Id, Context.FExcludedPlatform) then
          Continue;
        if Context.HasExtension(['.m3u']) and not MatchText('.m3u', Info.Extensions) then
          Continue;
        var Match := ProbeCore(Context, Loader.Match);
        if Match = nil then
          Continue;
        Matches.Add(Match);
        Match.Format.SystemId := Info.Id;
        Match.Confidence := TCoreMatchConfidence.Fallback;
        for var Folder in Info.ScanFolders do
          if Hint.Contains('/' + Folder.ToLower + '/') then
            Match.Confidence := TCoreMatchConfidence.Hint;
      end;
    Result := ChooseCoreMatch(Context, Matches);
  finally
    Matches.Free;
  end;
end;

function EmulationPlatformOptions(Context: TCoreLoadContext): TArray<TCorePlatformOption>;
begin
  Context.PrepareArchive;
  var Optical := Context.IsDiscSource or Context.HasExtension(['.m3u']);
  if not Optical then
    SelectArchiveImage(Context);
  var Options := TList<TCorePlatformOption>.Create;
  try
    for var Info in TPlatformRegistry.All do
    begin
      var Suitable := not Optical and Context.HasExtension(Info.Extensions);
      if Optical then
        for var Registration in Registrations do
          for var Loader in Registration.FDiscPlatforms do
            if SameText(Loader.PlatformId, Info.Id) then
              Suitable := not Context.HasExtension(['.m3u']) or MatchText('.m3u', Info.Extensions);
      if Suitable then
      begin
        var Choice: TCorePlatformOption;
        Choice.Id := Info.Id;
        Choice.Name := Info.Name;
        Options.Add(Choice);
      end;
    end;
    if not Optical then
      for var Stage in [TCoreLoadStage.Source, TCoreLoadStage.Image, TCoreLoadStage.Header] do
      begin
        var Matches := CollectCoreMatches(Context, Stage);
        try
          for var Match in Matches do
          begin
            var Duplicate := False;
            for var Choice in Options do
              Duplicate := Duplicate or SameText(Choice.Id, Match.PlatformId);
            if not Duplicate then
            begin
              var Choice: TCorePlatformOption;
              Choice.Id := Match.PlatformId;
              var Info: TPlatformInfo;
              if TPlatformRegistry.Find(Choice.Id, Info) then
                Choice.Name := Info.Name
              else
                Choice.Name := Match.Id;
              Options.Add(Choice);
            end;
          end;
        finally
          Matches.Free;
        end;
      end;
    Options.Sort(TComparer<TCorePlatformOption>.Construct(
      function(const Left, Right: TCorePlatformOption): Integer
      begin
        Result := CompareText(Left.Name, Right.Name);
      end));
    Result := Options.ToArray;
  finally
    Options.Free;
  end;
end;

function ResolveEmulationImage(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := SelectRecognizedCore(Context, TCoreLoadStage.Image);
  if Result <> nil then
    Exit;
  var Matches := CollectCoreMatches(Context, TCoreLoadStage.Header);
  try
    Context.FHeaderRecognized := Matches.Count > 0;
    Context.HeaderFormat := Default(TRomFormatInfo);
    for var Match in Matches do
      if AcceptsSelectedPlatform(Context, Match) then
      begin
        Context.HeaderFormat := Match.Format;
        Break;
      end;
    var Overrides := CollectCoreMatches(Context, TCoreLoadStage.OverrideHint);
    try
      while Overrides.Count > 0 do
      begin
        var OverrideMatch := Overrides.Extract(Overrides[0]);
        // A same-platform override can refine normalization. A different
        // platform is additional evidence, not permission to silently replace it.
        for var I := Matches.Count - 1 downto 0 do
          if SameText(Matches[I].PlatformId, OverrideMatch.PlatformId) then
            Matches.Delete(I);
        Matches.Add(OverrideMatch);
      end;
    finally
      Overrides.Free;
    end;
    Result := ChooseCoreMatch(Context, Matches);
  finally
    Matches.Free;
  end;
end;

function ResolveEmulationCore(Context: TCoreLoadContext; const PlatformId, ExcludedPlatformId: string): TCoreMatch;
begin
  Context.FExcludedPlatform := TPlatformRegistry.CanonicalId(ExcludedPlatformId);
  Context.FSelectedPlatform := PlatformId.Trim.ToLower;
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(PlatformId, Info) then
    Context.FSelectedPlatform := Info.Id;
  Context.PrepareArchive;
  if (Context.SelectedPlatform <> '') and (Context.IsDiscSource or Context.HasExtension(['.m3u'])) then
    Exit(SelectDiscPlatform(Context));
  Result := SelectRecognizedCore(Context, TCoreLoadStage.Source, TCoreMatchConfidence.Hint);
  if (Result = nil) and (Context.IsDiscSource or Context.HasExtension(['.m3u'])) then
    Exit(SelectDiscPlatform(Context));
  if Result = nil then
  begin
    Result := RecognizeEmulationCore(Context, TCoreLoadStage.Container);
    if (Result <> nil) and not AcceptsSelectedPlatform(Context, Result) then
      FreeAndNil(Result);
  end;
  if Result = nil then
  begin
    SelectArchiveImage(Context);
    if Context.ArchiveEntry then
      Result := SelectRecognizedCore(Context, TCoreLoadStage.Source, TCoreMatchConfidence.Hint);
    if (Result = nil) and (Context.IsDiscSource or Context.HasExtension(['.m3u'])) then
      Exit(SelectDiscPlatform(Context));
    if Result = nil then
      Result := ResolveEmulationImage(Context);
  end;
end;

procedure SelectArchiveImage(Context: TCoreLoadContext);
begin
  if Context.Archive = nil then
    Exit;
  var Archive := Context.Archive;
  var Saved := Context.Stream.Position;
  try
    var Candidate := -1;
    for var i := 0 to Archive.Count - 1 do
    begin
      TStorage.CheckReadCancelled;
      if Archive.Entries[i].IsDirectory then
        Continue;
      var Name := Archive.Entries[i].Name;
      if Name.Contains('__MACOSX/') or ExtractFileName(Name).StartsWith('._') or
        Name.EndsWith('/') or Name.EndsWith('\') then
        Continue;
      var Size := Archive.Entries[i].Size;
      var Suitable := False;
      for var Registration in Registrations do
      begin
        Suitable := MatchText(ExtractFileExt(Name), Registration.ArchiveExtensions) or
          (Assigned(Registration.ExtraArchiveCandidate) and Registration.ExtraArchiveCandidate(Context, Name, Size));
        if Suitable then
          Break;
      end;
      // No global extension whitelist: every registered image recognizer also
      // sees unknown entry names, so content detection also works in archives.
      if not Suitable and (Size <= MAX_ARCHIVE_IMAGE_SIZE) then
      begin
        var Bytes: TBytes;
        Archive.Read(i, Bytes);
        var Input := TBytesStream.Create(Bytes);
        try
          var Probe := TCoreLoadContext.Create(Input, Context.Storage, Context.RomName, Name, True);
          try
            Probe.FExcludedPlatform := Context.FExcludedPlatform;
            var Match := RecognizeEmulationCore(Probe, TCoreLoadStage.Source);
            if Match = nil then
              Match := RecognizeEmulationCore(Probe, TCoreLoadStage.Container);
            if Match = nil then
            try
              Match := ResolveEmulationImage(Probe);
            except
              on E: ECoreSelectionRequired do
                Suitable := True;
            end;
            try
              Suitable := Suitable or ((Match <> nil) and Match.ArchiveCandidate);
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
      if not Suitable then
        Continue;
      if Candidate >= 0 then
      begin
        var OldName := Archive.Entries[Candidate].Name;
        var Preference := -1;
        for var Registration in Registrations do
          if Assigned(Registration.ArchivePreference) then
          begin
            Preference := Registration.ArchivePreference(OldName, Name);
            if Preference >= 0 then
              Break;
          end;
        if Preference = 0 then
          Continue;
        // Identical archive contents must select the same image. Prefer
        // verified dumps over alternates/bad dumps, then use a stable name tie.
        if Preference < 0 then
        begin
          var Score := CartridgeVariantScore(Name);
          var Previous := CartridgeVariantScore(OldName);
          if (Score < Previous) or ((Score = Previous) and (CompareText(Name, OldName) >= 0)) then
            Continue;
        end;
      end;
      Candidate := i;
    end;
    if Candidate >= 0 then
    begin
      var Name := Archive.Entries[Candidate].Name;
      var Limit := Int64(MAX_ARCHIVE_IMAGE_SIZE);
      for var Registration in Registrations do
        if MatchText(ExtractFileExt(Name), Registration.ArchiveExtensions) then
          Limit := Max(Limit, Registration.MaxArchiveImageSize);
      if Archive.Entries[Candidate].Size > UInt64(Limit) then
        raise EReadError.CreateFmt('Cartridge archive image exceeds %d MiB', [Limit div (1024 * 1024)]);
      for var Registration in Registrations do
        if Assigned(Registration.ArchiveImageName) then
          Name := Registration.ArchiveImageName(Name);
      var Bytes: TBytes;
      Archive.Read(Candidate, Bytes);
      Context.LoadArchiveEntry(Bytes, Name);
      Exit;
    end;
  finally
    Archive := nil;
    if not Context.ArchiveEntry then
      Context.Stream.Position := Saved;
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

