unit RM.Gamepad.Factory;

interface

uses
  System.Classes, RM.Gamepad.Base;

type
  TGamepadDeviceVariant = record
    DeviceId: string;
    GamepadClass: TPlatformGamepadClass;
    class function Create(const DeviceId: string; GamepadClass: TPlatformGamepadClass): TGamepadDeviceVariant; static;
  end;

// Platform modules register once during static initialization. Unknown devices
// use DefaultClass; device IDs retain their original case-sensitive semantics.
procedure RegisterPlatformGamepads(const PlatformId: string; DefaultClass: TPlatformGamepadClass; const Variants: array of TGamepadDeviceVariant);

function TryGamepadClass(const SystemId, Device: string; out Value: TPlatformGamepadClass): Boolean;

function GamepadClass(const SystemId: string; const Device: string): TPlatformGamepadClass;

function CreatePlatformGamepad(Owner: TComponent; const SystemId: string; const Device: string): TPlatformGamepad;

implementation

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  Core.Platforms;

type
  TGamepadRegistration = record
    DefaultClass: TPlatformGamepadClass;
    Variants: TArray<TGamepadDeviceVariant>;
  end;

var
  Registrations: TDictionary<string, TGamepadRegistration>;

class function TGamepadDeviceVariant.Create(const DeviceId: string; GamepadClass: TPlatformGamepadClass): TGamepadDeviceVariant;
begin
  Result.DeviceId := DeviceId;
  Result.GamepadClass := GamepadClass;
end;

procedure RegisterPlatformGamepads(const PlatformId: string; DefaultClass: TPlatformGamepadClass; const Variants: array of TGamepadDeviceVariant);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (DefaultClass = nil) then
    raise EArgumentException.Create('Invalid platform gamepads: ' + PlatformId);
  if Registrations.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform gamepads: ' + Id);
  var Item: TGamepadRegistration;
  Item.DefaultClass := DefaultClass;
  SetLength(Item.Variants, Length(Variants));
  for var I := 0 to High(Variants) do
  begin
    if (Variants[I].DeviceId = '') or (Variants[I].GamepadClass = nil) then
      raise EArgumentException.Create('Invalid gamepad device variant: ' + Id);
    for var J := 0 to I - 1 do
      if Variants[J].DeviceId = Variants[I].DeviceId then
        raise EArgumentException.Create('Duplicate gamepad device variant: ' + Variants[I].DeviceId);
    Item.Variants[I] := Variants[I];
  end;
  Registrations.Add(Id, Item);
end;

function TryGamepadClass(const SystemId, Device: string; out Value: TPlatformGamepadClass): Boolean;
begin
  Value := nil;
  var Id := SystemId.Trim.ToLower;
  var Item: TGamepadRegistration;
  // A module can supply a distinct controller for a metadata alias. Otherwise
  // aliases and historical folder IDs use the canonical platform registration.
  Result := Registrations.TryGetValue(Id, Item);
  if not Result then
    Result := Registrations.TryGetValue(TPlatformRegistry.CanonicalId(Id), Item);
  if not Result then
    Exit;
  Value := Item.DefaultClass;
  for var Variant in Item.Variants do
    if Variant.DeviceId = Device then
    begin
      Value := Variant.GamepadClass;
      Exit;
    end;
end;

function GamepadClass(const SystemId: string; const Device: string): TPlatformGamepadClass;
begin
  if not TryGamepadClass(SystemId, Device, Result) then
    raise EArgumentException.Create('No virtual gamepad for this platform');
end;

function CreatePlatformGamepad(Owner: TComponent; const SystemId: string; const Device: string): TPlatformGamepad;
begin
  Result := GamepadClass(SystemId, Device).Create(Owner);
end;

initialization
  Registrations := TDictionary<string, TGamepadRegistration>.Create(TIStringComparer.Ordinal);

finalization
  Registrations.Free;

end.

