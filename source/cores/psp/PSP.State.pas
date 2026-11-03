unit PSP.State;

// Portable reconstruction states. The input history and the initial host data
// rebuild guest operations; no host pointers, closures or decoder handles persist.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Snapshots,
  Core.Emulation.Types, PSP.Settings;

type
  TPSPStateRoots = array[0..3] of string; // memory stick, flash, host, PGF directory
  TPSPStateProgress = reference to function(Done, Total: UInt64): Boolean;

  TPSPStateInput = packed record
    Count: Cardinal;
    Buttons: Word;
    X, Y: SmallInt;
    Analog: Byte;
    function Expand: TEmulatorInput;
  end;

  TPSPReplayState = class
  private
    FSandbox: string;
    FOriginalRoots, FRoots: TPSPStateRoots;
    FPublishing: Boolean;
  public
    InitialFiles: TBytes;
    Inputs: TList<TPSPStateInput>;
    Settings: TPSPSettings;
    Frames: UInt64;
    Digest, MediaDigest: TBytes;
    HasDisplay, NoEmulatorDevice, NoClobber: Boolean;
    CaptureError: string;
    constructor Create;
    destructor Destroy; override;
    procedure Capture(const Roots: TPSPStateRoots);
    procedure TrackRoots(const Roots: TPSPStateRoots);
    procedure Materialize(const OriginalRoots: TPSPStateRoots);
    procedure HostChanged(const Name: string; Time: TDateTime; Created: Boolean = False; Tree: Boolean = False);
    procedure RecordInput(const Input: TEmulatorInput);
    procedure Transfer(State: TStateArchive; VersionRead: Boolean = False);
    procedure CopyDataFrom(Source: TPSPReplayState);
    function LiveRoots: TPSPStateRoots;
    property Roots: TPSPStateRoots read FRoots;
    property Publishing: Boolean read FPublishing write FPublishing;
  end;

procedure PSPStateBytes(State: TStateArchive; var Data: TBytes; Limit: Integer);

implementation

uses
  System.IOUtils, System.ZLib, System.Math;

const
  MaxFilesSize = 48 * 1024 * 1024;
  MaxEntries = 20000;
  StateVersion = 1;

procedure PSPStateBytes(State: TStateArchive; var Data: TBytes; Limit: Integer);
begin
  // Length(dynamic array) is NativeInt: persist an explicitly sized count.
  var N: Integer := Length(Data);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > Limit) then
    raise EReadError.Create('PSP snapshot field exceeds its size limit');
  if State.Loading then
    SetLength(Data, N);
  if N > 0 then
    State.Field(Data[0], N);
end;

procedure StateString(State: TStateArchive; var Text: string);
begin
  var Data := TEncoding.UTF8.GetBytes(Text);
  PSPStateBytes(State, Data, 4096);
  if State.Loading then
    Text := TEncoding.UTF8.GetString(Data);
end;

function TPSPStateInput.Expand: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if (Buttons and (1 shl Ord(B))) <> 0 then
      Include(Result.Buttons, B);
  Result.Analog[0].Valid := Analog <> 0;
  Result.Analog[0].X := X;
  Result.Analog[0].Y := Y;
end;

constructor TPSPReplayState.Create;
begin
  inherited;
  Inputs := TList<TPSPStateInput>.Create;
end;

destructor TPSPReplayState.Destroy;
  procedure Writable(const Path: string; IsDirectory: Boolean);
  begin
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
    var Attr: TFileAttributes;
{$WARN SYMBOL_PLATFORM ON}
    if IsDirectory then
      Attr := TDirectory.GetAttributes(Path)
    else
      Attr := TFile.GetAttributes(Path);
{$IFDEF MSWINDOWS}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
    Exclude(Attr, TFileAttribute.faReadOnly);
{$WARN SYMBOL_PLATFORM ON}
{$ELSE}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
    Include(Attr, TFileAttribute.faOwnerWrite);
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
    if IsDirectory then
      TDirectory.SetAttributes(Path, Attr)
    else
      TFile.SetAttributes(Path, Attr);
  end;
begin
  Inputs.Free;
  // Only our uniquely created directory, never a path read from a state file.
  if (FSandbox <> '') and TDirectory.Exists(FSandbox) then
    try
      Writable(FSandbox, True);
      for var Dir in TDirectory.GetDirectories(FSandbox, '*', TSearchOption.soAllDirectories) do
        Writable(Dir, True);
      for var FileName in TDirectory.GetFiles(FSandbox, '*', TSearchOption.soAllDirectories) do
        Writable(FileName, False);
      TDirectory.Delete(FSandbox, True);
    except
      // Cleanup must not replace a load/cancellation error.
    end;
  inherited;
end;

procedure TPSPReplayState.Capture(const Roots: TPSPStateRoots);
var
  Raw: TMemoryStream;
  Archive: TStateArchive;
  Entries: Integer;

  procedure AddTree(Root: Integer; const Name, Relative: string);
  begin
    var IsDir := TDirectory.Exists(Name);
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
    var Attr: TFileAttributes;
{$WARN SYMBOL_PLATFORM ON}
    if IsDir then
      Attr := TDirectory.GetAttributes(Name, False)
    else
      Attr := TFile.GetAttributes(Name, False);
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
    if TFileAttribute.faSymLink in Attr then
{$WARN SYMBOL_PLATFORM ON}
      raise EReadError.Create('PSP snapshot host folders must not contain symbolic links');
    Inc(Entries);
    if Entries > MaxEntries then
      raise EReadError.Create('Too many files for a PSP snapshot');
    var Path := Relative;
    var Created, Modified: TDateTime;
    var ReadOnly :=
{$IFDEF MSWINDOWS}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
      TFileAttribute.faReadOnly in Attr
{$WARN SYMBOL_PLATFORM ON}
{$ELSE}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
      not (TFileAttribute.faOwnerWrite in Attr)
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
      ;
    var Data: TBytes := nil;
    if IsDir then
    begin
      Created := TDirectory.GetCreationTime(Name);
      Modified := TDirectory.GetLastWriteTime(Name);
    end
    else
    begin
      if TFile.GetSize(Name) > MaxFilesSize - Raw.Size then
        raise EReadError.Create('PSP snapshot initial host data exceeds 48 MiB');
      Created := TFile.GetCreationTime(Name);
      Modified := TFile.GetLastWriteTime(Name);
      var FileStream := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
      try
        SetLength(Data, FileStream.Size);
        if Length(Data) > 0 then
          FileStream.ReadBuffer(Data[0], Length(Data));
      finally
        FileStream.Free;
      end;
    end;
    Archive.Field(Root, SizeOf(Root));
    StateString(Archive, Path);
    Archive.Field(IsDir, SizeOf(IsDir));
    Archive.Field(Created, SizeOf(Created));
    Archive.Field(Modified, SizeOf(Modified));
    Archive.Field(ReadOnly, SizeOf(ReadOnly));
    PSPStateBytes(Archive, Data, MaxFilesSize);
    if Raw.Size > MaxFilesSize then
      raise EReadError.Create('PSP snapshot initial host data exceeds 48 MiB');
    if IsDir then
      for var Child in TDirectory.GetFileSystemEntries(Name) do
        AddTree(Root, Child, Relative + '/' + ExtractFileName(Child));
  end;

begin
  FRoots := Roots;
  Settings := PSPSettings;
  Inputs.Clear;
  Frames := 0;
  Digest := nil;
  InitialFiles := nil;
  CaptureError := '';
  Raw := TMemoryStream.Create;
  Archive := TStateArchive.Create(Raw, False);
  try
    try
      Entries := 0;
      for var I := 0 to High(Roots) do
      begin
        var Present := Roots[I] <> '';
        Archive.Field(Present, SizeOf(Present));
      end;
      for var I := 0 to High(Roots) do
        if (Roots[I] <> '') and TDirectory.Exists(Roots[I]) then
          AddTree(I, Roots[I], '');
      var EndMarker := -1;
      Archive.Field(EndMarker, SizeOf(EndMarker));
      var PackedData := TMemoryStream.Create;
      try
        var Compressor := TZCompressionStream.Create(PackedData);
        try
          Raw.Position := 0;
          Compressor.CopyFrom(Raw, Raw.Size);
        finally
          Compressor.Free;
        end;
        SetLength(InitialFiles, PackedData.Size);
        Move(PackedData.Memory^, InitialFiles[0], Length(InitialFiles));
      finally
        PackedData.Free;
      end;
    except
      on E: Exception do
        CaptureError := E.Message;
    end;
  finally
    Archive.Free;
    Raw.Free;
  end;
end;

procedure TPSPReplayState.TrackRoots(const Roots: TPSPStateRoots);
begin
  FRoots := Roots;
  Settings := PSPSettings;
  CaptureError := '';
end;

procedure TPSPReplayState.Materialize(const OriginalRoots: TPSPStateRoots);
type
  TStamp = record
    Path: string;
    Created, Modified: TDateTime;
    ReadOnly, Directory: Boolean;
  end;
begin
  FOriginalRoots := OriginalRoots;
  FPublishing := False;
  var Id := TGUID.NewGuid.ToString;
  FSandbox := TPath.Combine(TPath.GetTempPath, 'RetroMul-PSP-' + Id);
  TDirectory.CreateDirectory(FSandbox);
  var Input := TBytesStream.Create(InitialFiles);
  var Raw := TMemoryStream.Create;
  var Stamps := TList<TStamp>.Create;
  try
    var Decompressor := TZDecompressionStream.Create(Input);
    try
      var Buffer: array[0..65535] of Byte;
      while True do
      begin
        var N := Decompressor.Read(Buffer, SizeOf(Buffer));
        if N = 0 then
          Break;
        if Raw.Size + N > MaxFilesSize then
          raise EReadError.Create('PSP snapshot host data is too large');
        Raw.WriteBuffer(Buffer, N);
      end;
    finally
      Decompressor.Free;
    end;
    Raw.Position := 0;
    var Archive := TStateArchive.Create(Raw, True);
    try
      for var I := 0 to High(FRoots) do
      begin
        var Present := False;
        Archive.Field(Present, SizeOf(Present));
        if Present then
          FRoots[I] := TPath.Combine(FSandbox, IntToStr(I))
        else
          FRoots[I] := '';
      end;
      var Entries := 0;
      while True do
      begin
        var Root := 0;
        Archive.Field(Root, SizeOf(Root));
        if Root = -1 then
          Break;
        if (Root < 0) or (Root > High(FRoots)) or (FRoots[Root] = '') then
          raise EReadError.Create('Invalid PSP snapshot root');
        Inc(Entries);
        if Entries > MaxEntries then
          raise EReadError.Create('Too many snapshot files');
        var Relative := '';
        StateString(Archive, Relative);
        if (Relative <> '') and not Relative.StartsWith('/') then
          raise EReadError.Create('Invalid PSP snapshot path');
        if Relative.Contains('\') or Relative.Contains(':') then
          raise EReadError.Create('Invalid PSP snapshot path');
        for var Part in Relative.Split(['/']) do
        begin
          if (Part = '.') or (Part = '..') or Part.EndsWith('.') or Part.EndsWith(' ') then
            raise EReadError.Create('Unsafe PSP snapshot path');
          for var C in Part do
            if (Ord(C) < 32) or CharInSet(C, ['<', '>', '"', '|', '*', '?']) then
              raise EReadError.Create('Unsafe PSP snapshot filename');
        end;
        var S := Default(TStamp);
        Archive.Field(S.Directory, SizeOf(S.Directory));
        Archive.Field(S.Created, SizeOf(S.Created));
        Archive.Field(S.Modified, SizeOf(S.Modified));
        Archive.Field(S.ReadOnly, SizeOf(S.ReadOnly));
        var Data: TBytes := nil;
        PSPStateBytes(Archive, Data, MaxFilesSize);
        S.Path := FRoots[Root] + Relative.Replace('/', PathDelim);
        if S.Directory then
          TDirectory.CreateDirectory(S.Path)
        else
        begin
          TDirectory.CreateDirectory(ExtractFileDir(S.Path));
          TFile.WriteAllBytes(S.Path, Data);
        end;
        Stamps.Add(S);
      end;
      if Raw.Position <> Raw.Size then
        raise EReadError.Create('Unexpected PSP snapshot files');
      for var I := Stamps.Count - 1 downto 0 do
      begin
        var S := Stamps[I];
        if S.Directory then
        begin
          TDirectory.SetCreationTime(S.Path, S.Created);
          TDirectory.SetLastWriteTime(S.Path, S.Modified);
        end
        else
        begin
          TFile.SetCreationTime(S.Path, S.Created);
          TFile.SetLastWriteTime(S.Path, S.Modified);
        end;
        if S.ReadOnly then
        begin
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
          var Attr: TFileAttributes;
{$WARN SYMBOL_PLATFORM ON}
          if S.Directory then
            Attr := TDirectory.GetAttributes(S.Path)
          else
            Attr := TFile.GetAttributes(S.Path);
{$IFDEF MSWINDOWS}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
          Include(Attr, TFileAttribute.faReadOnly);
{$WARN SYMBOL_PLATFORM ON}
{$ELSE}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
          Attr := Attr - [TFileAttribute.faOwnerWrite, TFileAttribute.faGroupWrite, TFileAttribute.faOthersWrite];
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
          if S.Directory then
            TDirectory.SetAttributes(S.Path, Attr)
          else
            TFile.SetAttributes(S.Path, Attr);
        end;
      end;
    finally
      Archive.Free;
    end;
  finally
    Stamps.Free;
    Raw.Free;
    Input.Free;
  end;
end;

procedure TPSPReplayState.HostChanged(const Name: string; Time: TDateTime; Created, Tree: Boolean);
  procedure PublishFile(const Source, Target: string);
  begin
    if TFile.Exists(Target) then
    begin
      var Attr := TFile.GetAttributes(Target);
{$IFDEF MSWINDOWS}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
      Exclude(Attr, TFileAttribute.faReadOnly);
{$WARN SYMBOL_PLATFORM ON}
{$ELSE}
{$WARN SYMBOL_PLATFORM OFF} // IOUtils attributes are selected for this host below.
      Include(Attr, TFileAttribute.faOwnerWrite);
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
      TFile.SetAttributes(Target, Attr);
    end;
    var Input := TFileStream.Create(Source, fmOpenRead or fmShareDenyNone);
    try
      var Output := TFileStream.Create(Target, fmCreate or fmShareDenyNone);
      try
        Output.CopyFrom(Input, Input.Size);
      finally
        Output.Free;
      end;
    finally
      Input.Free;
    end;
    TFile.SetCreationTime(Target, TFile.GetCreationTime(Source));
    TFile.SetLastWriteTime(Target, TFile.GetLastWriteTime(Source));
    TFile.SetAttributes(Target, TFile.GetAttributes(Source));
  end;

  procedure PublishDirectory(const Source, Target: string);
  begin
    TDirectory.CreateDirectory(Target);
    for var Child in TDirectory.GetDirectories(Source) do
      PublishDirectory(Child, TPath.Combine(Target, ExtractFileName(Child)));
    for var Child in TDirectory.GetFiles(Source) do
      PublishFile(Child, TPath.Combine(Target, ExtractFileName(Child)));
  end;
begin
  for var I := 0 to High(FRoots) do
  begin
    if FRoots[I] = '' then
      Continue;
    var Prefix := IncludeTrailingPathDelimiter(TPath.GetFullPath(FRoots[I]));
    var Full := TPath.GetFullPath(Name);
    if not Full.StartsWith(Prefix, {$IFDEF MSWINDOWS} True {$ELSE} False {$ENDIF}) then
      Continue;
    if Created then
    begin
      if TDirectory.Exists(Full) then
        TDirectory.SetCreationTime(Full, Time)
      else if TFile.Exists(Full) then
        TFile.SetCreationTime(Full, Time);
    end;
    // Stamp guest mutations with the guest RTC, including parent directory changes.
    var P := Full;
    while P.Length >= Prefix.Length do
    begin
      if TDirectory.Exists(P) then
        TDirectory.SetLastWriteTime(P, Time)
      else if TFile.Exists(P) then
        TFile.SetLastWriteTime(P, Time);
      P := ExtractFileDir(P);
    end;
    if not FPublishing or (FOriginalRoots[I] = '') then
      Exit;
    var Target := TPath.Combine(FOriginalRoots[I], Full.Substring(Prefix.Length));
    if TDirectory.Exists(Full) then
    begin
      if Tree then
        PublishDirectory(Full, Target)
      else
        TDirectory.CreateDirectory(Target);
      TDirectory.SetCreationTime(Target, TDirectory.GetCreationTime(Full));
      TDirectory.SetLastWriteTime(Target, Time);
      TDirectory.SetAttributes(Target, TDirectory.GetAttributes(Full));
    end
    else if TFile.Exists(Full) then
    begin
      TDirectory.CreateDirectory(ExtractFileDir(Target));
      PublishFile(Full, Target);
      TFile.SetLastWriteTime(Target, Time);
    end
    else if TFile.Exists(Target) then
      TFile.Delete(Target)
    else if TDirectory.Exists(Target) then
      TDirectory.Delete(Target, True);
    Exit;
  end;
end;

function TPSPReplayState.LiveRoots: TPSPStateRoots;
begin
  if FSandbox <> '' then
    Result := FOriginalRoots
  else
    Result := FRoots;
end;

procedure TPSPReplayState.RecordInput(const Input: TEmulatorInput);
begin
  var R := Default(TPSPStateInput);
  R.Count := 1;
  for var B in Input.Buttons do
    R.Buttons := R.Buttons or (1 shl Ord(B));
  R.Analog := Ord(Input.Analog[0].Valid);
  R.X := Input.Analog[0].X;
  R.Y := Input.Analog[0].Y;
  if Inputs.Count > 0 then
  begin
    var Last := Inputs.Last;
    if (Last.Buttons = R.Buttons) and (Last.Analog = R.Analog) and (Last.X = R.X) and (Last.Y = R.Y) and
      (Last.Count < High(Cardinal)) then
    begin
      Inc(Last.Count);
      Inputs[Inputs.Count - 1] := Last;
      Inc(Frames);
      Exit;
    end;
  end;
  Inputs.Add(R);
  Inc(Frames);
end;

procedure TPSPReplayState.Transfer(State: TStateArchive; VersionRead: Boolean);
begin
  var Version := StateVersion;
  if not VersionRead then
    State.Field(Version, SizeOf(Version));
  if Version <> StateVersion then
    raise EReadError.Create('Unsupported PSP reconstruction state version');
  PSPStateBytes(State, InitialFiles, MaxFilesSize + 65536);
  PSPStateBytes(State, Digest, 32);
  PSPStateBytes(State, MediaDigest, 32);
  State.Field(Frames, SizeOf(Frames));
  State.Field(HasDisplay, SizeOf(HasDisplay));
  State.Field(NoEmulatorDevice, SizeOf(NoEmulatorDevice));
  State.Field(NoClobber, SizeOf(NoClobber));
  StateString(State, Settings.Nickname);
  State.Field(Settings.Language, SizeOf(Settings.Language));
  State.Field(Settings.ButtonSwap, SizeOf(Settings.ButtonSwap));
  State.Field(Settings.Timezone, SizeOf(Settings.Timezone));
  State.Field(Settings.DaylightSaving, SizeOf(Settings.DaylightSaving));
  State.Field(Settings.DateFormat, SizeOf(Settings.DateFormat));
  State.Field(Settings.TimeFormat, SizeOf(Settings.TimeFormat));
  State.Field(Settings.AdhocChannel, SizeOf(Settings.AdhocChannel));
  State.Field(Settings.WlanPowerSave, SizeOf(Settings.WlanPowerSave));
  State.Field(Settings.ParentalLevel, SizeOf(Settings.ParentalLevel));
  var Count: Integer := Inputs.Count;
  State.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 1000000) then
    raise EReadError.Create('Too many PSP input runs');
  var Total: UInt64 := 0;
  if State.Loading then
    Inputs.Clear;
  for var I := 0 to Count - 1 do
  begin
    var R := Default(TPSPStateInput);
    if not State.Loading then
      R := Inputs[I];
    State.Field(R, SizeOf(R));
    if (R.Count = 0) or (R.Analog > 1) or (R.Buttons >= (1 shl 13)) then
      raise EReadError.Create('Invalid PSP input run');
    Inc(Total, R.Count);
    if State.Loading then
      Inputs.Add(R);
  end;
  if (Total <> Frames) or (Frames > UInt64(60) * 60 * 60 * 24 * 7) then
    raise EReadError.Create('Invalid PSP snapshot duration');
end;

procedure TPSPReplayState.CopyDataFrom(Source: TPSPReplayState);
begin
  InitialFiles := Source.InitialFiles;
  Settings := Source.Settings;
  Frames := Source.Frames;
  Digest := Source.Digest;
  MediaDigest := Source.MediaDigest;
  HasDisplay := Source.HasDisplay;
  NoEmulatorDevice := Source.NoEmulatorDevice;
  NoClobber := Source.NoClobber;
  CaptureError := Source.CaptureError;
  Inputs.Clear;
  Inputs.AddRange(Source.Inputs);
end;

end.
