unit MSX.Firmware;

interface

uses
  System.SysUtils, MSX.Machine;

procedure LoadMSXFirmware(Model: TMSXModel; out Main, Sub, Logo, Music: TBytes);

procedure LoadMSXOriginalFirmware(Model: TMSXModel; out Main, Sub, Disk, Music, Kanji, KanjiBasic: TBytes);

function LoadMSXFMPAC: TBytes;

function LoadMSXAudioFirmware(Panasonic: Boolean): TBytes;

implementation

uses
  System.Classes;

{$R 'MSX.Firmware.res' 'MSX.Firmware.rc'}

function Firmware(const Name: string; Size: Integer): TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    if Stream.Size <> Size then
      raise EReadError.Create('Invalid MSX firmware: ' + Name);
    SetLength(Result, Size);
    Stream.ReadBuffer(Result[0], Size);
  finally
    Stream.Free;
  end;
end;

function LoadMSXFMPAC: TBytes;
begin
  Result := Firmware('MSX_FMPAC', $10000);
end;

function LoadMSXAudioFirmware(Panasonic: Boolean): TBytes;
begin
  if Panasonic then
    Result := Firmware('MSX_AUDIO_FSCA1', $20000)
  else
    Result := Firmware('MSX_AUDIO_NMS1205', $8000);
end;

procedure LoadMSXOriginalFirmware(Model: TMSXModel; out Main, Sub, Disk, Music, Kanji, KanjiBasic: TBytes);
begin
  Main := nil;
  Sub := nil;
  Music := nil;
  Kanji := nil;
  KanjiBasic := nil;
  Disk := Firmware('MSX_PHILIPS_DISK', $4000);
  case Model of
    MSX1:
      Main := Firmware('MSX_BASIC_1', $8000);
    MSX2:
      begin
        Main := Firmware('MSX_BASIC_2', $8000);
        Sub := Firmware('MSX_ORIGINAL_SUB_2', $4000);
      end;
    MSX2Plus:
      begin
        Main := Firmware('MSX_BASIC_2P', $8000);
        Sub := Firmware('MSX_ORIGINAL_SUB_2P', $4000);
        Music := Firmware('MSX_ORIGINAL_MUSIC', $4000);
        Kanji := Firmware('MSX_KANJI', $40000);
        KanjiBasic := Firmware('MSX_KANJI_BASIC', $8000);
      end;
  end;
end;

procedure LoadMSXFirmware(Model: TMSXModel; out Main, Sub, Logo, Music: TBytes);
const
  MainIDs: array[TMSXModel] of string = ('MSX_MAIN_1', 'MSX_MAIN_2', 'MSX_MAIN_2P');
  LogoIDs: array[TMSXModel] of string = ('MSX_LOGO_1', 'MSX_LOGO_2', 'MSX_LOGO_2P');
begin
  Main := Firmware(MainIDs[Model], $8000);
  Logo := Firmware(LogoIDs[Model], $4000);
  Sub := nil;
  Music := nil;
  if Model <> MSX1 then
    Sub := Firmware('MSX_SUB', $4000);
  if Model = MSX2Plus then
    Music := Firmware('MSX_MUSIC', $4000);
end;

end.

