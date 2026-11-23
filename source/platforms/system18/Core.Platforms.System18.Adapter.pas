unit Core.Platforms.System18.Adapter;

interface

uses
  System.Classes, Core.Storage, Core.Emulation, Core.Platforms.SegaArcade.Adapter,
  Core.Emulation.Types;

type
  TS18CoreAdapter = class(TSegaArcadeCoreAdapter, IEmulationPointerInput, IEmulationMouseInput)
  private
    FPointer: TEmulatorAnalogPad;
    FMouseButtons: Byte;
    FPointerActive: Boolean;
    FTrackball: Boolean;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    procedure ClearInput; override;
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    function GetInputState: TEmulatorInput; override;
  end;

implementation

uses
  System.Math, System.SysUtils, SegaArcade.Video, S18.Cartridge,
  S18.Console;

constructor TS18CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  InitializeCore(TS18Cartridge.Create(Stream, RomName, Storage), TS18Console,
    Storage, RomName, 'system18', 'Sega System 18', 'System18');
  FTrackball := FCart.RomSet.Inputs.StartsWith('wwally');
end;

procedure TS18CoreAdapter.ClearInput;
begin
  FPointer := Default(TEmulatorAnalogPad);
  FPointerActive := False;
  FMouseButtons := 0;
  inherited;
end;

function TS18CoreAdapter.GetUsesPointer: Boolean;
begin
  Result := FCart.RomSet.Inputs = 'lghost';
end;

procedure TS18CoreAdapter.SetPointer(X, Y: Integer; Valid: Boolean);
begin
  if not GetUsesPointer then
    Exit;
  FPointerActive := Valid;
  FPointer.Valid := True;
  if Valid then
  begin
    FPointer.X := EnsureRange(X, 0, SEGA_ARCADE_WIDTH - 1) * 65535 div (SEGA_ARCADE_WIDTH - 1) - 32768;
    FPointer.Y := EnsureRange(Y, 0, SEGA_ARCADE_HEIGHT - 1) * 65535 div (SEGA_ARCADE_HEIGHT - 1) - 32768;
  end
  else
  begin
    FPointer.X := Low(SmallInt);
    FPointer.Y := Low(SmallInt);
  end;
  UpdateInput;
end;

procedure TS18CoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if not (GetUsesPointer or FTrackball) or not InputPortEnabled(0) then
    Exit;
  if FTrackball and ((DX <> 0) or (DY <> 0)) then
    AddPointerMotion(DX, DY);
  FMouseButtons := Buttons;
  UpdateInput;
end;

function TS18CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := inherited;
  for var I := 0 to 2 do
  begin
    if not InputPortEnabled(I) then
      Result.Analog[I].Valid := False
    else if GetUsesPointer and FPointer.Valid and
      (not Result.Analog[I].Valid or ((I = 0) and FPointerActive)) then
      Result.Analog[I] := FPointer;
  end;
  if not InputPortEnabled(0) then
    Exit;
  if FMouseButtons and 1 <> 0 then
    Include(Result.Buttons, TEmulatorButton.A);
  if FMouseButtons and 2 <> 0 then
    Include(Result.Buttons, TEmulatorButton.B);
end;

end.

