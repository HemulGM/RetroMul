unit MSX.Machine;

interface

uses
  System.SysUtils;

type
  TMSXModel = (MSX1, MSX2, MSX2Plus);

  TMSXVDPChip = (VDPAuto, VDPTMS9918A, VDPTMS9929A, VDPTMS9118, VDPTMS9129,
    VDPT7937A, VDPT6950, VDPV9938A, VDPV9938B, VDPV9938C, VDPV9958);

  TMSXHostKeys = array[0..255] of Boolean;

  TMSXMediaKind = (CartridgeMedia, DiskMedia, CASMedia, WAVMedia);

  TMSXPeripheralOptions = record
    VDPChip: TMSXVDPChip;
    VDPWaitConnected: Boolean;
    DiskROM, KanjiROM, KanjiBasicROM, MusicROM, Cartridge2: TBytes;
    DiskA, DiskB, Tape: TBytes;
    Mapper2, TapeBaud, TapeMode, MousePort, AudioSampleRAM: Integer; // tape: 0 stopped, 1 play, 2 record
    TapeCAS, DiskWriteProtected: Boolean;
  end;

function MSXSystemId(Model: TMSXModel): string;

function MSXModelName(Model: TMSXModel): string;

implementation

function MSXSystemId(Model: TMSXModel): string;
const
  IDs: array[TMSXModel] of string = ('msx1', 'msx2', 'msx2plus');
begin
  Result := IDs[Model];
end;

function MSXModelName(Model: TMSXModel): string;
const
  Names: array[TMSXModel] of string = ('MSX1', 'MSX2', 'MSX2+');
begin
  Result := Names[Model];
end;

end.

