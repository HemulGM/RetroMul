unit Core.EmulatorFactory;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore; overload;

// The caller owns Stream. Construction copies and validates its remaining bytes.
function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string = ''): IEmulationCore; overload;

implementation

uses
  Core.RomFormat, Core.Adapter.NES, Core.Adapter.GB, Core.Adapter.GBC,
  Core.Adapter.MD;

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
  var Data := ReadRomData(Stream);
  var Format := DetectRom(Data);
  if Format.System = TRomSystem.Unknown then
    raise EReadError.Create('Unrecognized ROM header (NES, Game Boy, Game Boy Color or Mega Drive expected)');
  Data := NormalizeRom(Data, Format);
  var Input := TBytesStream.Create(Data);
  try
    case Format.System of
      TRomSystem.NES:
        Result := TNesCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GB:
        Result := TGBCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GBC:
        Result := TGBCCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.MD:
        Result := TMDCoreAdapter.Create(Input, Storage, RomName);
    end;
  finally
    Input.Free;
  end;
end;

end.

