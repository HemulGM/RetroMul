unit J2ME.UI.Data;

interface

uses
  JVM.Types, JVM.Runtime;

const
  J2MEUI = 'javax/microedition/lcdui/';

function UIInt(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;

function UILong(O: TJVMObject; const Name: string; Default: Int64 = 0): Int64;

function UIRef(O: TJVMObject; const Name: string): Integer;

procedure UIPut(O: TJVMObject; const Name: string; Value: Integer);

procedure UIPutLong(O: TJVMObject; const Name: string; Value: Int64);

procedure UIPutRef(O: TJVMObject; const Name: string; Value: Integer);

function UIString(VM: TJVM; Ref: Integer): string;

procedure UIInitItem(O: TJVMObject; LabelRef: Integer);

function UIImageSnapshot(VM: TJVM; Ref: Integer): Integer;

procedure UIInvalidateOwner(VM: TJVM; O: TJVMObject);

implementation

uses
  J2ME.Image;

function UIInt(O: TJVMObject; const Name: string; Default: Integer): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function UILong(O: TJVMObject; const Name: string; Default: Int64): Int64;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsLong
  else
    Result := Default;
end;

function UIRef(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure UIPut(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Int(Value));
end;

procedure UIPutLong(O: TJVMObject; const Name: string; Value: Int64);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Long(Value));
end;

procedure UIPutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Ref(Value));
end;

function UIString(VM: TJVM; Ref: Integer): string;
begin
  Result := '';
  if Ref <> 0 then
    Result := VM.GetObject(Ref).Text;
end;

procedure UIInitItem(O: TJVMObject; LabelRef: Integer);
begin
  UIPutRef(O, 'label', LabelRef);
  UIPut(O, 'preferredWidth', -1);
  UIPut(O, 'preferredHeight', -1);
end;

function UIImageSnapshot(VM: TJVM; Ref: Integer): Integer;
begin
  Result := Ref;
  if Ref = 0 then
    Exit;
  var View := J2MEImageView(VM, Ref);
  if not View.Mutable then
    Exit;
  Result := J2MENewMutableImage(VM, View.Width, View.Height);
  var Snapshot := J2MEImageView(VM, Result);
  Snapshot.Pixels.Elements := Copy(View.Pixels.Elements);
  Snapshot.Image.Fields[J2MEUI + 'Image.$mutable:Z'] := TJVMValue.Int(0);
end;

procedure UIInvalidateOwner(VM: TJVM; O: TJVMObject);
begin
  var Ref := UIRef(O, 'owner');
  if Ref = 0 then
    Exit;
  var Owner := VM.GetObject(Ref);
  if VM.IsAssignable(Owner.ClassName, J2MEUI + 'Form') then
    UIPut(Owner, 'version', UIInt(Owner, 'version') + 1);
end;

end.

