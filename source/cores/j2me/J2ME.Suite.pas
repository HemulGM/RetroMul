unit J2ME.Suite;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Storage,
  Core.Archive.Container;

const
  J2MEManifestName = 'META-INF/MANIFEST.MF';

type
  TJ2MEMIDlet = record
    Name, Icon, ClassName: string;
  end;

  TJ2MESuite = class
  private
    FArchive: IArchiveContainer;
    FStorage: IStorage;
    FEntries: TDictionary<string, Integer>;
    FProperties, FManifestProperties, FJADProperties: TDictionary<string, string>;
    FMIDlets: TArray<TJ2MEMIDlet>;
    FManifestName, FManifestText, FJADText, FJADLoadError: string;
    procedure ValidateStandaloneJAD(JarSize: Int64);
    function HasMIDletAncestor(const ClassName: string): Boolean;
    procedure ReadProperties(const Data: TBytes; MainSection: Boolean);
    procedure ReadMIDlets;
  public
    constructor Create(const Archive: IArchiveContainer; const JAD: TBytes = nil; const Storage: IStorage = nil; JarSize: Int64 = -1);
    destructor Destroy; override;
    class function Open(Input: TStream; const Storage: IStorage; const JAD: TBytes = nil): TJ2MESuite; static;
    function ReadResource(const Name: string): TBytes;
    function HasResource(const Name: string): Boolean;
    function LoadClass(const Name: string): TBytes;
    function GetProperty(const Name: string): string;
    function HasProperty(const Name: string): Boolean;
    function Properties(const Source: string = ''): TArray<TPair<string, string>>;
    function PropertySource(const Name: string): string;
    function ClassNames: TArray<string>;
    function SourceText(const Source: string): string;
    function MIDletCount: Integer;
    function MIDlet(Index: Integer): TJ2MEMIDlet;
    property Storage: IStorage read FStorage;
    property Archive: IArchiveContainer read FArchive;
    property ManifestName: string read FManifestName;
    property JADLoadError: string read FJADLoadError;
  end;

implementation

uses
  Core.Archive.Zip, JVM.ClassFile;

function TrimAttribute(const S: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(S);
  while (First <= Last) and CharInSet(S[First], [#9, ' ']) do
    Inc(First);
  while (Last >= First) and CharInSet(S[Last], [#9, ' ']) do
    Dec(Last);
  Result := Copy(S, First, Last - First + 1);
end;

function DecodeDescriptor(const Data: TBytes): string;
begin
  try
    Result := TEncoding.UTF8.GetString(Data);
  except
    on EEncodingError do
    begin
      // Older manifests and descriptors can contain ISO-8859-1 text.
      SetLength(Result, Length(Data));
      for var I := 0 to High(Data) do
        Result[I + 1] := Char(Data[I]);
    end;
  end;
end;

procedure TJ2MESuite.ReadProperties(const Data: TBytes; MainSection: Boolean);
var
  Unfolded: TBytes;
  I, N, P: Integer;
  Lines: TArray<string>;
  Line, Key, Value: string;
begin
  if Length(Data) > 1024 * 1024 then
    raise EReadError.Create('J2ME descriptor exceeds 1 MiB');
  // Unfold before UTF-8 decoding: a manifest continuation can split a code point.
  SetLength(Unfolded, Length(Data));
  I := 0;
  N := 0;
  while I < Length(Data) do
  begin
    if Data[I] in [10, 13] then
    begin
      var Next := I + 1;
      if (Data[I] = 13) and (Next < Length(Data)) and (Data[Next] = 10) then
        Inc(Next);
      if (Next < Length(Data)) and (Data[Next] = 32) then
        I := Next + 1
      else
      begin
        Unfolded[N] := 10;
        Inc(N);
        I := Next;
      end;
    end
    else
    begin
      Unfolded[N] := Data[I];
      Inc(N);
      Inc(I);
    end;
  end;
  SetLength(Unfolded, N);
  var Text := DecodeDescriptor(Unfolded);
  Lines := Text.Split([#10]);
  if (Length(Lines) > 0) and Lines[0].StartsWith(Char($FEFF)) then
    Delete(Lines[0], 1, 1);
  for Line in Lines do
  begin
    if Line = '' then
    begin
      if MainSection then
        Break
      else
        Continue;
    end;
    // Some archival JAD editors leave full-line comments in descriptors.
    if not MainSection and Line.StartsWith('#') then
      Continue;
    P := Pos(':', Line);
    if P < 2 then
      raise EReadError.Create('Invalid J2ME descriptor attribute');
    Key := Copy(Line, 1, P - 1);
    Value := TrimAttribute(Copy(Line, P + 1, MaxInt));
    FProperties.AddOrSetValue(Key, Value);
    if MainSection then
      FManifestProperties.AddOrSetValue(Key, Value)
    else
      FJADProperties.AddOrSetValue(Key, Value);
  end;
end;

constructor TJ2MESuite.Create(const Archive: IArchiveContainer; const JAD: TBytes; const Storage: IStorage; JarSize: Int64);
var
  I, Index, Existing, FallbackIndex: Integer;
  Entry: TArchiveEntry;
  Total: UInt64;
  Data, Duplicate: TBytes;
  AmbiguousFallback: Boolean;

  procedure ReadManifest(EntryIndex: Integer; out Bytes: TBytes);
  begin
    if Archive.Entries[EntryIndex].Size > 1024 * 1024 then
      raise EReadError.Create('Manifest exceeds 1 MiB');
    Archive.Read(EntryIndex, Bytes);
  end;

  procedure ValidateEntryPoints;
  begin
    if Index < 0 then
      ValidateStandaloneJAD(JarSize);
    if (GetProperty('MicroEdition-Configuration') <> '') and
      (GetProperty('MicroEdition-Configuration') <> 'CLDC-1.0') and
      (GetProperty('MicroEdition-Configuration') <> 'CLDC-1.1') then
      raise EReadError.Create('Unsupported Java ME configuration');
    for var Profile in GetProperty('MicroEdition-Profile').Split([' '], TStringSplitOptions.ExcludeEmpty) do
      if (Profile <> 'MIDP-1.0') and (Profile <> 'MIDP-2.0') then
        raise EReadError.Create('Unsupported Java ME profile: ' + Profile);
    ReadMIDlets;
    if Index < 0 then
      for var Item in FMIDlets do
        if not HasMIDletAncestor(Item.ClassName) then
          raise EReadError.Create('JAD entry class does not extend MIDlet: ' + Item.ClassName);
  end;

begin
  inherited Create;
  if Archive = nil then
    raise EArgumentNilException.Create('Archive');
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FArchive := Archive;
  FEntries := TDictionary<string, Integer>.Create;
  FProperties := TDictionary<string, string>.Create;
  FManifestProperties := TDictionary<string, string>.Create;
  FJADProperties := TDictionary<string, string>.Create;
  Total := 0;
  FallbackIndex := -1;
  AmbiguousFallback := False;
  for I := 0 to Archive.Count - 1 do
  begin
    Entry := Archive.Entries[I];
    if Entry.IsDirectory then
      Continue;
    if (Entry.Size > 16 * 1024 * 1024) or (Total + Entry.Size > 64 * 1024 * 1024) then
      raise EReadError.Create('J2ME suite exceeds resource size limits');
    Inc(Total, Entry.Size);
    if Entry.Name.Contains('\') or Entry.Name.StartsWith('/') or
      ('/' + Entry.Name + '/').Contains('/../') then
      raise EReadError.Create('Invalid or duplicate JAR member: ' + Entry.Name);
    var IsManifest := SameText(Entry.Name, J2MEManifestName);
    if FEntries.TryGetValue(Entry.Name, Existing) then
    begin
      if not IsManifest or (Entry.Size <> Archive.Entries[Existing].Size) then
        raise EReadError.Create('Invalid or duplicate JAR member: ' + Entry.Name);
      ReadManifest(Existing, Data);
      ReadManifest(I, Duplicate);
      if (Length(Data) <> Length(Duplicate)) or
        not CompareMem(Pointer(Data), Pointer(Duplicate), Length(Data)) then
        raise EReadError.Create('Invalid or duplicate JAR member: ' + Entry.Name);
      Continue;
    end;
    FEntries.Add(Entry.Name, I);
    if IsManifest then
    begin
      AmbiguousFallback := FallbackIndex >= 0;
      FallbackIndex := I;
    end;
  end;
  // Prefer the canonical JAR name. A lone spelling variant also serves as
  // a manifest, while an exact duplicate is accepted only after byte comparison.
  if not FEntries.TryGetValue(J2MEManifestName, Index) then
  begin
    if AmbiguousFallback then
      raise EReadError.Create('Ambiguous archive member: ' + J2MEManifestName);
    Index := FallbackIndex;
  end;
  if Index >= 0 then
  begin
    ReadManifest(Index, Data);
    ReadProperties(Data, True);
    FManifestName := Archive.Entries[Index].Name;
    FManifestText := DecodeDescriptor(Data);
  end
  else if Length(JAD) = 0 then
    raise EReadError.Create('JAR has no manifest or companion JAD');

  if Length(JAD) = 0 then
  begin
    ValidateEntryPoints;
    Exit;
  end;

  try
    if Length(JAD) > 1024 * 1024 then
      raise EReadError.Create('J2ME descriptor exceeds 1 MiB');
    FJADText := DecodeDescriptor(JAD);
    ReadProperties(JAD, False);
    ValidateEntryPoints;
  except
    on E: EReadError do
    begin
      if Index < 0 then
        raise;
      // Treat the companion as a unit. The embedded descriptor must be
      // independently usable before we can run the original JAR by itself.
      FJADLoadError := E.Message;
      FJADProperties.Clear;
      FProperties.Clear;
      for var Pair in FManifestProperties do
        FProperties.Add(Pair.Key, Pair.Value);
      ValidateEntryPoints;
    end;
  end;
end;

procedure TJ2MESuite.ValidateStandaloneJAD(JarSize: Int64);
begin
  for var Key in ['MIDlet-Name', 'MIDlet-Vendor', 'MIDlet-Version', 'MIDlet-Jar-URL', 'MIDlet-1'] do
    if GetProperty(Key) = '' then
      raise EReadError.Create('JAD required attribute is missing: ' + Key);
  var Size := GetProperty('MIDlet-Jar-Size');
  for var Digit in Size do
    if not CharInSet(Digit, ['0'..'9']) then
      raise EReadError.Create('Invalid MIDlet-Jar-Size in standalone JAD');
  var DeclaredSize: Int64;
  if (JarSize <= 0) or not TryStrToInt64(Size, DeclaredSize) or (DeclaredSize <> JarSize) then
    raise EReadError.Create('MIDlet-Jar-Size in standalone JAD does not match the JAR');
end;

function TJ2MESuite.HasMIDletAncestor(const ClassName: string): Boolean;
const
  MIDletBase = 'javax/microedition/midlet/MIDlet';
begin
  Result := False;
  var Name := ClassName;
  var Seen := TDictionary<string, Boolean>.Create;
  try
    for var Depth := 0 to 255 do
    begin
      TStorage.CheckReadCancelled;
      if (Name = '') or (Name = 'java/lang/Object') or Seen.ContainsKey(Name) then
        Exit;
      var Data := LoadClass(Name);
      if Length(Data) = 0 then
        Exit;
      Seen.Add(Name, True);
      var C := TJVMClass.Parse(Data);
      try
        if C.Name <> Name then
          Exit;
        if C.SuperName = MIDletBase then
          Exit(True);
        Name := C.SuperName;
      finally
        C.Free;
      end;
    end;
  finally
    Seen.Free;
  end;
end;

destructor TJ2MESuite.Destroy;
begin
  FManifestProperties.Free;
  FJADProperties.Free;
  FProperties.Free;
  FEntries.Free;
  inherited;
end;

class function TJ2MESuite.Open(Input: TStream; const Storage: IStorage; const JAD: TBytes): TJ2MESuite;
begin
  if not IsZipArchive(Input) then
    raise EReadError.Create('J2ME application must be a JAR archive');
  var JarSize := Input.Size;
  Result := TJ2MESuite.Create(OpenZip(Input, Storage), JAD, Storage, JarSize);
end;

procedure TJ2MESuite.ReadMIDlets;
var
  I, A, B, N: Integer;
  S, ClassName: string;
begin
  FMIDlets := nil;
  for I := 1 to 1024 do
  begin
    S := GetProperty('MIDlet-' + IntToStr(I));
    if S = '' then
      Break;
    A := Pos(',', S);
    B := LastDelimiter(',', S);
    if (A = 0) or (B <= A) then
      raise EReadError.Create('Invalid MIDlet declaration');
    ClassName := TrimAttribute(Copy(S, B + 1, MaxInt)).Replace('.', '/');
    if (ClassName = '') or ClassName.Contains('..') or ClassName.StartsWith('/') or
      not FEntries.ContainsKey(ClassName + '.class') then
      raise EReadError.Create('MIDlet class is missing');
    N := Length(FMIDlets);
    SetLength(FMIDlets, N + 1);
    FMIDlets[N].Name := TrimAttribute(Copy(S, 1, A - 1));
    FMIDlets[N].Icon := TrimAttribute(Copy(S, A + 1, B - A - 1));
    FMIDlets[N].ClassName := ClassName;
  end;
  if Length(FMIDlets) = 0 then
    raise EReadError.Create('JAR contains no MIDlet-1');
end;

function TJ2MESuite.HasResource(const Name: string): Boolean;
var
  ResourceName: string;
begin
  ResourceName := Name;
  if ResourceName.StartsWith('/') then
    Delete(ResourceName, 1, 1);
  Result := FEntries.ContainsKey(ResourceName);
end;

function TJ2MESuite.Properties(const Source: string): TArray<TPair<string, string>>;
begin
  if Source = 'manifest' then
    Exit(FManifestProperties.ToArray);
  if Source = 'jad' then
    Exit(FJADProperties.ToArray);
  Result := FProperties.ToArray;
end;

function TJ2MESuite.PropertySource(const Name: string): string;
begin
  if FJADProperties.ContainsKey(Name) then
    Exit('jad');
  if FManifestProperties.ContainsKey(Name) then
    Exit('manifest');
  Result := '';
end;

function TJ2MESuite.ClassNames: TArray<string>;
begin
  var List := TList<string>.Create;
  try
    for var Name in FEntries.Keys do
      if Name.EndsWith('.class') then
        List.Add(Name.Substring(0, Length(Name) - 6));
    Result := List.ToArray;
  finally
    List.Free;
  end;
  TArray.Sort<string>(Result);
end;

function TJ2MESuite.SourceText(const Source: string): string;
begin
  Result := '';
  if Source = 'manifest' then
    Result := FManifestText;
  if Source = 'jad' then
    Result := FJADText;
end;

function TJ2MESuite.ReadResource(const Name: string): TBytes;
var
  Index: Integer;
  ResourceName: string;
begin
  ResourceName := Name;
  if ResourceName.StartsWith('/') then
    Delete(ResourceName, 1, 1);
  if FEntries.TryGetValue(ResourceName, Index) then
    FArchive.Read(Index, Result)
  else
    Result := nil;
end;

function TJ2MESuite.LoadClass(const Name: string): TBytes;
begin
  if Name.StartsWith('java/') or Name.StartsWith('javax/') then
    Exit(nil);
  Result := ReadResource(Name + '.class');
end;

function TJ2MESuite.GetProperty(const Name: string): string;
begin
  if not FProperties.TryGetValue(Name, Result) then
    Result := '';
end;

function TJ2MESuite.HasProperty(const Name: string): Boolean;
begin
  Result := FProperties.ContainsKey(Name);
end;

function TJ2MESuite.MIDletCount: Integer;
begin
  Result := Length(FMIDlets);
end;

function TJ2MESuite.MIDlet(Index: Integer): TJ2MEMIDlet;
begin
  if (Index < 0) or (Index >= Length(FMIDlets)) then
    raise EArgumentOutOfRangeException.Create('MIDlet index');
  Result := FMIDlets[Index];
end;

end.

