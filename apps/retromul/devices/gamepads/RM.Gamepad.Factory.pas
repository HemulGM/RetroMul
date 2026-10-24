unit RM.Gamepad.Factory;

interface

uses
  System.Classes, Core.Platforms, RM.Gamepad.Base;

function GamepadClass(System: TRomSystem; const Device: string): TPlatformGamepadClass;

function CreatePlatformGamepad(Owner: TComponent; System: TRomSystem; const Device: string): TPlatformGamepad;

implementation

uses
  System.SysUtils, RM.Gamepad.NES.Standart, RM.Gamepad.GB.Standart,
  RM.Gamepad.GBC.Standart, RM.Gamepad.GBA.Standart, RM.Gamepad.SNES.Standart,
  RM.Gamepad.N64.Standart, RM.Gamepad.Saturn.Digital, RM.Gamepad.Saturn.Analog,
  RM.Gamepad.NeoGeo.Arcade, RM.Gamepad.NeoGeo.AES, RM.Gamepad.NeoGeo.CD,
  RM.Gamepad.NGP.Standart, RM.Gamepad.NGPC.Standart, RM.Gamepad.SG1000.Standart,
  RM.Gamepad.SC3000.Standart, RM.Gamepad.SF7000.Standart,
  RM.Gamepad.SMS.Standart, RM.Gamepad.GameGear.Standart,
  RM.Gamepad.Multivision.Standart, RM.Gamepad.GameWatch.Standart,
  RM.Gamepad.NES.Dendy, RM.Gamepad.SEGA.Pad3, RM.Gamepad.SEGA.Pad6,
  RM.Gamepad.SEGA.MegaCD.Pad3, RM.Gamepad.SEGA.MegaCD.Pad6,
  RM.Gamepad.SEGA.Mega32X.Pad3, RM.Gamepad.SEGA.Mega32X.Pad6,
  RM.Gamepad.PCE.Pad2, RM.Gamepad.PCE.Pad6, RM.Gamepad.SuperGrafx.Pad2,
  RM.Gamepad.SuperGrafx.Pad6, RM.Gamepad.PCECD.Pad2, RM.Gamepad.PCECD.Pad6,
  RM.Gamepad.CPS.Arcade, RM.Gamepad.ZX, RM.Gamepad.PS1.Digital, RM.Gamepad.PS1.Analog;

function GamepadClass(System: TRomSystem; const Device: string): TPlatformGamepadClass;
begin
  case System of
    TRomSystem.ZXSpectrum:
      Result := TGamepadZX;
    TRomSystem.CPS1, TRomSystem.CPS2, TRomSystem.CPS3:
      Result := TGamepadCPSArcade;
    TRomSystem.NES:
      if Device = 'paddendy' then
        Result := TGamepadNESDendy
      else
        Result := TGamepadNESStandart;
    TRomSystem.GB:
      Result := TGamepadGBStandart;
    TRomSystem.GBC:
      Result := TGamepadGBCStandart;
    TRomSystem.GBA:
      Result := TGamepadGBAStandart;
    TRomSystem.SNES:
      Result := TGamepadSNESStandart;
    TRomSystem.N64:
      Result := TGamepadN64Standart;
    TRomSystem.PS1:
      if Device = 'pad-analog' then
        Result := TGamepadPS1Analog
      else
        Result := TGamepadPS1Digital;
    TRomSystem.Saturn:
      if Device = 'pad-analog' then
        Result := TGamepadSaturnAnalog
      else
        Result := TGamepadSaturnDigital;
    TRomSystem.NeoGeo:
      Result := TGamepadNeoGeoArcade;
    TRomSystem.NeoGeoAES:
      Result := TGamepadNeoGeoAES;
    TRomSystem.NeoGeoCD:
      Result := TGamepadNeoGeoCD;
    TRomSystem.NeoGeoPocket:
      Result := TGamepadNGPStandart;
    TRomSystem.NeoGeoPocketColor:
      Result := TGamepadNGPCStandart;
    TRomSystem.SG1000:
      Result := TGamepadSG1000Standart;
    TRomSystem.SC3000:
      Result := TGamepadSC3000Standart;
    TRomSystem.SF7000:
      Result := TGamepadSF7000Standart;
    TRomSystem.SMS:
      Result := TGamepadSMSStandart;
    TRomSystem.GameGear:
      Result := TGamepadGameGearStandart;
    TRomSystem.Multivision:
      Result := TGamepadMultivisionStandart;
    TRomSystem.GameWatch:
      Result := TGamepadGameWatchStandart;
    TRomSystem.MD:
      if Device = 'pad3' then
        Result := TGamepadSEGAPad3
      else
        Result := TGamepadSEGAPad6;
    TRomSystem.SegaCD:
      if Device = 'pad3' then
        Result := TGamepadSEGAMegaCDPad3
      else
        Result := TGamepadSEGAMegaCDPad6;
    TRomSystem.Sega32X:
      if Device = 'pad3' then
        Result := TGamepadSEGAMega32XPad3
      else
        Result := TGamepadSEGAMega32XPad6;
    TRomSystem.PCE:
      if Device = 'pad6' then
        Result := TGamepadPCEPad6
      else
        Result := TGamepadPCEPad2;
    TRomSystem.SuperGrafx:
      if Device = 'pad6' then
        Result := TGamepadSuperGrafxPad6
      else
        Result := TGamepadSuperGrafxPad2;
    TRomSystem.PCECD:
      if Device = 'pad6' then
        Result := TGamepadPCECDPad6
      else
        Result := TGamepadPCECDPad2;
  else
    raise EArgumentException.Create('No virtual gamepad for this platform');
  end;
end;

function CreatePlatformGamepad(Owner: TComponent; System: TRomSystem; const Device: string): TPlatformGamepad;
begin
  Result := GamepadClass(System, Device).Create(Owner);
end;

end.

