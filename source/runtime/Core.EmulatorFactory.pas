unit Core.EmulatorFactory;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore; overload;

// The caller owns Stream. Cores retain their own media/storage when needed.
// RomName always identifies the original location, including an enclosing archive.
function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string = ''): IEmulationCore; overload;

implementation

uses
  Core.EmulatorRegistry;

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

function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string): IEmulationCore;
begin
  var Context := TCoreLoadContext.Create(Stream, Storage, RomName);
  try
    var Match := ResolveEmulationCore(Context);
    if Match = nil then
    begin
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

