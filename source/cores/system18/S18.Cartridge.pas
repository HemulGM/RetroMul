unit S18.Cartridge;

interface

uses
  System.Classes, Core.Storage, SegaArcade.Cartridge;

type
  TS18Cartridge = class(TSegaArcadeCartridge)
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage = nil);
  end;

implementation

uses
  S18.RomSets;

constructor TS18Cartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage);
begin
  inherited Create(Stream, Name, Storage, 'Sega System 18', 'Sega System 18', IdentifySystem18Rom, FindSystem18Rom);
end;

end.

