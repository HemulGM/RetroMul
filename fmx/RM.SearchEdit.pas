unit RM.SearchEdit;

interface

uses
  System.Classes, FMX.Edit, FMX.Controls.Model;

type
  TSearchEdit = class(TEdit)
  private
    FClearButton: TClearEditButton;
    procedure UpdateClearButton;
  protected
    function DefineModelClass: TDataModelClass; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  FMX.Types, RM.Icons;

type
  TSearchEditModel = class(TCustomEditModel)
  protected
    procedure DoChangeTracking; override;
  end;

procedure TSearchEditModel.DoChangeTracking;
begin
  // Keep the button in sync before the existing search handler refreshes results.
  if Owner is TSearchEdit then
    TSearchEdit(Owner).UpdateClearButton;
  inherited;
end;

constructor TSearchEdit.Create(AOwner: TComponent);
begin
  inherited;
  StyleLookup := 'editstyle';
  FClearButton := TClearEditButton.Create(Self);
  FClearButton.Name := 'SearchClear';
  FClearButton.StyleLookup := 'transparentbuttonstyle';
  FClearButton.Width := 32;
  FClearButton.Hint := Translate('Clear search');
  FClearButton.ShowHint := True;
  AddButtonIcon(FClearButton, IconClose, 14);
  FClearButton.Parent := Self;
  UpdateClearButton;
end;

function TSearchEdit.DefineModelClass: TDataModelClass;
begin
  Result := TSearchEditModel;
end;

procedure TSearchEdit.UpdateClearButton;
begin
  if FClearButton <> nil then
    FClearButton.Visible := Text <> '';
end;

end.
