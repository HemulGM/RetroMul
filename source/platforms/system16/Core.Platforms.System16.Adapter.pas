unit Core.Platforms.System16.Adapter;

interface

uses
  System.Classes, Core.Storage, Core.Platforms.SegaArcade.Adapter;

type
  TS16Config = class(TSegaArcadeConfig)
  public
    constructor Create(const FileName: string; const Storage: IStorage);
  end;

  TS16CoreAdapter = class(TSegaArcadeCoreAdapter)
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
  end;

implementation

uses
  S16.Cartridge, S16.Console;

constructor TS16Config.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage, 'System16');
end;

constructor TS16CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  InitializeCore(TS16Cartridge.Create(Stream, RomName, Storage), TS16Console,
    Storage, RomName, 'system16', 'Sega System 16', 'System16');
end;

end.
