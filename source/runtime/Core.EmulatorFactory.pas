unit Core.EmulatorFactory;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore; overload;

// The caller owns Stream. Cores retain their own media/storage when needed.
// RomName always identifies the original location, including an enclosing archive.
function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string = ''; const PlatformId: string = ''; const PreferredPlatformId: string = ''): IEmulationCore; overload;

implementation

uses
  Core.EmulatorRegistry, Core.Platforms;

const
  MAX_UNRECOGNIZED_IMAGE_SIZE = 64 * 1024 * 1024;

function CreateEmulationCore(const FileName: string): IEmulationCore;
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName, PlatformId, PreferredPlatformId: string): IEmulationCore;
begin
  // A library category is an explicit first attempt. Do not auto-detect a
  // competing core or ask the user before that platform reports a load error.
  if (PreferredPlatformId <> '') and (PlatformId = '') then
  begin
    var Position := Stream.Position;
    var LoadError: string;
    try
      Exit(CreateEmulationCore(Stream, Storage, RomName, PreferredPlatformId));
    except
      on E: EAbort do
        raise;
      on E: Exception do
        LoadError := E.Message;
    end;
    Stream.Position := Position;
    var Probe := TCoreLoadContext.Create(Stream, Storage, RomName);
    try
      var Choices := EmulationPlatformOptions(Probe);
      var Found := False;
      for var Choice in Choices do
        Found := Found or SameText(Choice.Id, PreferredPlatformId);
      var Info: TPlatformInfo;
      if not Found and TPlatformRegistry.Find(PreferredPlatformId, Info) then
      begin
        var Choice: TCorePlatformOption;
        Choice.Id := Info.Id;
        Choice.Name := Info.Name;
        Choices := Choices + [Choice];
      end;
      if Length(Choices) = 0 then
        raise EReadError.Create(LoadError);
      raise ECoreSelectionRequired.Create(Choices, PreferredPlatformId, LoadError);
    finally
      Probe.Free;
    end;
  end;
  var Context := TCoreLoadContext.Create(Stream, Storage, RomName);
  try
    var Match := ResolveEmulationCore(Context, PlatformId);
    if Match = nil then
    begin
      if PlatformId <> '' then
        raise EReadError.Create('Unrecognized ROM header or unsupported media');
      if Length(Context.Data) > MAX_UNRECOGNIZED_IMAGE_SIZE then
        raise EReadError.Create('ROM exceeds 64 MiB');
      raise EReadError.Create('Unrecognized ROM header or unsupported media');
    end;
    try
      Result := Match.CreateCore;
    finally
      Match.Free;
    end;
  finally
    Context.Free;
  end;
end;

end.

