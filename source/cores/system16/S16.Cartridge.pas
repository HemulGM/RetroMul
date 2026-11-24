unit S16.Cartridge;

interface

uses
  System.Classes, Core.Storage, SegaArcade.Cartridge;

type
  ES16Rom = ESegaArcadeRom;

  TS16Cartridge = class(TSegaArcadeCartridge)
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage = nil); overload;
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage; const platform: string; Identify: TSegaRomIdentify; Find: TSegaRomFind); overload;
  end;

implementation

uses
  S16.RomSets;

constructor TS16Cartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage);
begin
  inherited Create(Stream, Name, Storage, 'Sega System 16', 'System16', IdentifySystem16Rom, FindSystem16Rom);
end;

constructor TS16Cartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage; const platform: string; Identify: TSegaRomIdentify; Find: TSegaRomFind);
begin
  inherited Create(Stream, Name, Storage, platform, platform, Identify, Find);
end;

end.

