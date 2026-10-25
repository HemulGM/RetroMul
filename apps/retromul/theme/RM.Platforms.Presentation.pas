unit RM.Platforms.Presentation;

interface

uses
  Core.Platforms;

{$SCOPEDENUMS ON}

type
  TPlatformPadLayout = (Nes, Sega, Snes, GameBoy, GameBoyColor, NeoGeo, Dendy, GameBoyAdvance, Nintendo64, PCE, CPS,
    PlayStation);

const
  SETTINGS_PAGE_MAIN = 0;
  SETTINGS_PAGE_GB = 1;
  SETTINGS_PAGE_GBC = 2;
  SETTINGS_PAGE_NES = 3;
  SETTINGS_PAGE_MD = 4;
  SETTINGS_PAGE_SNES = 5;
  SETTINGS_PAGE_NEOGEO = 6;
  SETTINGS_PAGE_GBA = 7;
  SETTINGS_PAGE_N64 = 8;
  SETTINGS_PAGE_SG1000 = 9;
  SETTINGS_PAGE_SC3000 = 10;
  SETTINGS_PAGE_SF7000 = 11;
  SETTINGS_PAGE_MULTIVISION = 12;
  SETTINGS_PAGE_SMS = 13;
  SETTINGS_PAGE_GG = 14;
  SETTINGS_PAGE_GW = 15;
  SETTINGS_PAGE_PCE = 16;
  SETTINGS_PAGE_SGX = 17;
  SETTINGS_PAGE_PCECD = 18;
  SETTINGS_PAGE_NEOGEOCD = 19;
  SETTINGS_PAGE_SATURN = 20;
  SETTINGS_PAGE_NEOGEOAES = SETTINGS_PAGE_NEOGEO;
  SETTINGS_PAGE_NGP = 22;
  SETTINGS_PAGE_NGPC = 23;
  SETTINGS_PAGE_CPS1 = 24;
  SETTINGS_PAGE_CPS2 = 25;
  SETTINGS_PAGE_CPS3 = 26;
  SETTINGS_PAGE_PS1 = 27;
  SETTINGS_PAGE_ZX = 28;
  SETTINGS_PAGE_PS2 = 29;

type
  TPlatformPresentation = record
    SettingsPageId: Integer;
    PadLayout: TPlatformPadLayout;
    IconData: string;
  end;

function PlatformPresentation(System: TRomSystem): TPlatformPresentation; overload;

function PlatformPresentation(const Id: string): TPlatformPresentation; overload;

implementation

uses
  System.SysUtils, Core.Platforms.Icons;

function PlatformPresentation(System: TRomSystem): TPlatformPresentation;
begin
  Result := Default(TPlatformPresentation);
  case System of
    TRomSystem.ZXSpectrum:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_ZX;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconSC3000;
      end;
    TRomSystem.CPS1, TRomSystem.CPS2, TRomSystem.CPS3:
      begin
        case System of
          TRomSystem.CPS1: Result.SettingsPageId := SETTINGS_PAGE_CPS1;
          TRomSystem.CPS2: Result.SettingsPageId := SETTINGS_PAGE_CPS2;
          TRomSystem.CPS3: Result.SettingsPageId := SETTINGS_PAGE_CPS3;
        end;
        Result.PadLayout := TPlatformPadLayout.CPS;
        Result.IconData := PlatformIconCPS;
      end;
    TRomSystem.GameWatch:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_GW;
        Result.PadLayout := TPlatformPadLayout.Snes;
        Result.IconData := PlatformIconGW;
      end;
    TRomSystem.GB:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_GB;
        Result.PadLayout := TPlatformPadLayout.GameBoy;
        Result.IconData := PlatformIconGB;
      end;
    TRomSystem.GBC:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_GBC;
        Result.PadLayout := TPlatformPadLayout.GameBoyColor;
        Result.IconData := PlatformIconGBC;
      end;
    TRomSystem.GBA:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_GBA;
        Result.PadLayout := TPlatformPadLayout.GameBoyAdvance;
        Result.IconData := PlatformIconGBA;
      end;
    TRomSystem.NES:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_NES;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconNES;
      end;
    TRomSystem.SNES:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SNES;
        Result.PadLayout := TPlatformPadLayout.Snes;
        Result.IconData := PlatformIconSNES;
      end;
    TRomSystem.Saturn:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SATURN;
        Result.PadLayout := TPlatformPadLayout.Sega;
        Result.IconData := PlatformIconSaturn;
      end;
    TRomSystem.PS1:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_PS1;
        Result.PadLayout := TPlatformPadLayout.PlayStation;
        Result.IconData := PlatformIconPS1;
      end;
    TRomSystem.PS2:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_PS2;
        Result.PadLayout := TPlatformPadLayout.PlayStation;
        Result.IconData := PlatformIconPS2;
      end;
    TRomSystem.N64:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_N64;
        Result.PadLayout := TPlatformPadLayout.Nintendo64;
        Result.IconData := PlatformIconN64;
      end;
    TRomSystem.MD, TRomSystem.SegaCD, TRomSystem.Sega32X:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_MD;
        Result.PadLayout := TPlatformPadLayout.Sega;
        Result.IconData := PlatformIconMD;
      end;
    TRomSystem.SG1000:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SG1000;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconSG1000;
      end;
    TRomSystem.SC3000:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SC3000;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconSC3000;
      end;
    TRomSystem.SF7000:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SF7000;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconSF7000;
      end;
    TRomSystem.SMS:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SMS;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconSMS;
      end;
    TRomSystem.GameGear:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_GG;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconGG;
      end;
    TRomSystem.Multivision:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_MULTIVISION;
        Result.PadLayout := TPlatformPadLayout.Nes;
        Result.IconData := PlatformIconOMV;
      end;
    TRomSystem.NeoGeo:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_NEOGEO;
        Result.PadLayout := TPlatformPadLayout.NeoGeo;
        Result.IconData := PlatformIconNEOGEO;
      end;
    TRomSystem.NeoGeoAES:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_NEOGEOAES;
        Result.PadLayout := TPlatformPadLayout.NeoGeo;
        Result.IconData := PlatformIconNEOGEO;
      end;
    TRomSystem.NeoGeoPocket, TRomSystem.NeoGeoPocketColor:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_NGP;
        if System = TRomSystem.NeoGeoPocketColor then
          Result.SettingsPageId := SETTINGS_PAGE_NGPC;
        Result.PadLayout := TPlatformPadLayout.GameBoy;
        Result.IconData := PlatformIconGB;
      end;
    TRomSystem.NeoGeoCD:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_NEOGEOCD;
        Result.PadLayout := TPlatformPadLayout.NeoGeo;
        Result.IconData := PlatformIconNEOGEOCD;
      end;
    TRomSystem.PCE:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_PCE;
        Result.PadLayout := TPlatformPadLayout.PCE;
        Result.IconData := PlatformIconPCE;
      end;
    TRomSystem.SuperGrafx:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_SGX;
        Result.PadLayout := TPlatformPadLayout.PCE;
        Result.IconData := PlatformIconSGX;
      end;
    TRomSystem.PCECD:
      begin
        Result.SettingsPageId := SETTINGS_PAGE_PCECD;
        Result.PadLayout := TPlatformPadLayout.PCE;
        Result.IconData := PlatformIconPCECD;
      end;
  else
    raise EArgumentException.Create('Unknown platform presentation');
  end;
end;

function PlatformPresentation(const Id: string): TPlatformPresentation;
begin
  Result := PlatformPresentation(TPlatformRegistry.Require(Id).System);
end;

end.

