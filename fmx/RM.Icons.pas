unit RM.Icons;

interface

uses
  System.Types, System.UITypes, FMX.Types, FMX.Controls, FMX.Objects,
  FMX.StdCtrls, FMX.Graphics;

const
  IconBack = 'M24,13 L2,13 M10,5 L2,13 L10,21';
  IconChevronDown = 'M2,4 L12,14 L22,4';
  IconClose = 'M4,4 L20,20 M20,4 L4,20';
  IconMore = 'M4,10 C6.7,10 6.7,14 4,14 C1.3,14 1.3,10 4,10 Z M12,10 C14.7,10 14.7,14 12,14 C9.3,14 9.3,10 12,10 Z M20,10 C22.7,10 22.7,14 20,14 C17.3,14 17.3,10 20,10 Z';
  IconViewList = 'M2,4 L22,4 M2,12 L22,12 M2,20 L22,20';
  IconViewGrid = 'M2,2 L10,2 L10,10 L2,10 Z M14,2 L22,2 L22,10 L14,10 Z M2,14 L10,14 L10,22 L2,22 Z M14,14 L22,14 L22,22 L14,22 Z';
  IconRewind = 'M11,4 L2,12 L11,20 M22,4 L13,12 L22,20';
  IconForward = 'M2,4 L11,12 L2,20 M13,4 L22,12 L13,20';

  IconPad = 'M10,6 L24,6 C28,6 30,8 31,13 L34,26 C35,30 31,32 28,29 L23,24 L11,24 L6,29 C3,32 0,30 1,26 L4,13 C5,8 6,6 10,6 Z M9,12 L9,21 M5,16 L13,16 M24,13 L24,15 M28,18 L28,20';
  IconLibrary = 'M2,2 L10,2 L10,10 L2,10 Z M16,2 L24,2 L24,10 L16,10 Z M2,16 L10,16 L10,24 L2,24 Z M16,16 L24,16 L24,24 L16,24 Z';
  IconClock = 'M13,1 C29,1 29,25 13,25 C-3,25 -3,1 13,1 Z M13,6 L13,13 L19,16';
  IconHeart = 'M13,23 L3,13 C-5,3 8,-2 13,7 C18,-2 31,3 23,13 Z';
  IconFolder = 'M1,6 L10,6 L13,9 L25,9 L25,25 L1,25 Z';
  IconGear = 'M10,1 L16,1 L17,5 L21,7 L25,6 L28,11 L25,14 L25,18 L28,21 L25,26 L21,25 L17,27 L16,31 L10,31 L9,27 L5,25 L1,26 L-2,21 L1,18 L1,14 L-2,11 L1,6 L5,7 L9,5 Z M13,10 C21,10 21,22 13,22 C5,22 5,10 13,10 Z';
  IconDisplay = 'M1,1 L25,1 L25,18 L1,18 Z M13,18 L13,24 M6,24 L20,24';
  IconCoin = 'M14,1 C31,1 31,27 14,27 C-3,27 -3,1 14,1 Z M14,5 C25,5 25,23 14,23 C3,23 3,5 14,5 Z M14,9 L14,19';
  IconPause = 'M4,2 L4,24 M16,2 L16,24';
  IconPlay = 'M4,2 L23,13 L4,24 Z';
  IconSave = 'M2,2 L21,2 L26,7 L26,26 L2,26 Z M7,2 L7,11 L19,11 L19,2 M7,26 L7,17 L21,17 L21,26';
  IconLoad = 'M1,7 L10,7 L13,10 L26,10 L26,26 L1,26 Z M14,1 L14,17 M9,12 L14,17 L19,12';
  IconCamera = 'M1,7 L7,7 L10,2 L19,2 L22,7 L28,7 L28,25 L1,25 Z M14,10 C23,10 23,22 14,22 C5,22 5,10 14,10 Z';
  IconFullScreen = 'M1,9 L1,1 L9,1 M19,1 L27,1 L27,9 M27,19 L27,27 L19,27 M9,27 L1,27 L1,19';
  IconSpeaker = 'M1,10 L7,10 L15,3 L15,25 L7,18 L1,18 Z M20,8 C27,11 27,17 20,20 M24,3 C36,8 36,20 24,25';
  IconRestart = 'M1,10 C1,0 23,0 23,10 M23,10 L23,2 M23,10 L15,10 M23,16 C23,26 1,26 1,16';
  IconArrowUp = 'M0,-4 L3,3 L-3,3 Z';

function CreatePathIcon(Parent: TControl; const Data: string; X, Y, Size: Single; Color: TAlphaColor = $FFB9C2CC): TPath;

function AddButtonIcon(Button: TCustomButton; const Data: string; Size: Single = 16; Color: TAlphaColor = $FFE8ECF1): TPath;

implementation

function CreatePathIcon(Parent: TControl; const Data: string; X, Y, Size: Single; Color: TAlphaColor): TPath;
begin
  Result := TPath.Create(Parent);
  Result.Parent := Parent;
  Result.Data.Data := Data;
  Result.WrapMode := TPathWrapMode.Fit;
  Result.Fill.Kind := TBrushKind.None;
  Result.Stroke.Color := Color;
  Result.Stroke.Thickness := 1.6;
  Result.HitTest := False;
  Result.SetBounds(X, Y, Size, Size);
end;

function AddButtonIcon(Button: TCustomButton; const Data: string; Size: Single; Color: TAlphaColor): TPath;
begin
  Button.Text := '';
  Result := CreatePathIcon(Button, Data, 0, 0, Size, Color);
  Result.Name := 'ButtonIcon';
  Result.Align := TAlignLayout.Center;
  Button.ShowHint := Button.Hint <> '';
end;

end.

