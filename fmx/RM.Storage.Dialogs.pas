unit RM.Storage.Dialogs;

interface

uses
  Core.Storage;

type
  TStoragePicker = class(TInterfacedObject, IStoragePicker)
  public
    procedure Select(Folder: Boolean; const Callback: TStorageSelectionCallback);
  end;

implementation

uses
  System.SysUtils, FMX.OpenDialog;

procedure TStoragePicker.Select(Folder: Boolean; const Callback: TStorageSelectionCallback);
begin
  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.MultipleSelection := False;
    var Completion: TFMXSelectionCallback :=
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        if Assigned(Callback) then
          Callback(Result);
      end;
    if Folder then
    begin
      Dialog.Title := 'Select ROM folder';
      Dialog.SelectFolder(Completion);
    end
    else
    begin
      Dialog.Title := 'Open ROM';
      // Content detection allows renamed ROMs and provider-specific MIME types.
      Dialog.Filter := 'All files|*';
      Dialog.SelectFiles(Completion);
    end;
  finally
    Dialog.Free;
  end;
end;

end.

