unit RetroTune.ReferenceForm;

interface

uses
  System.Classes, FMX.Forms, FMX.Layouts, FMX.Edit, FMX.StdCtrls;

type
  TTuneReferenceForm = class(TForm)
  private
    FTitleLabel, FSubtitleLabel: TLabel;
    FSection: TLayout;
    FCard: TPanel;
    FContentHeight: Single;
    FRowCount: Integer;
  protected
    FScroll: TVertScrollBox;
    procedure SetHeading(const Title, Subtitle: string);
    procedure ClearContent;
    procedure AddSection(const Title: string);
    function AddField(const Name, Value: string): TEdit;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.UITypes, FMX.Types, FMX.Controls, FMX.BehaviorManager;

constructor TTuneReferenceForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'RetroTune';
  ClientWidth := 880;
  ClientHeight := 760;
  Constraints.MinWidth := 640;
  Constraints.MinHeight := 480;
  Position := TFormPosition.ScreenCenter;
  var Background := TPanel.Create(Self);
  Background.Parent := Self;
  Background.Align := TAlignLayout.Contents;
  Background.StyleLookup := 'panelstyle_appbackground';
  var Page := TLayout.Create(Self);
  Page.Parent := Background;
  Page.Align := TAlignLayout.Client;
  Page.Margins.Left := 24;
  Page.Margins.Right := 24;
  Page.Margins.Top := 24;
  Page.Margins.Bottom := 24;
  var Header := TLayout.Create(Self);
  Header.Parent := Page;
  Header.Align := TAlignLayout.Top;
  Header.Height := 68;
  Header.Margins.Bottom := 24;
  FTitleLabel := TLabel.Create(Self);
  FTitleLabel.Parent := Header;
  FTitleLabel.Align := TAlignLayout.Top;
  FTitleLabel.Height := 36;
  FTitleLabel.StyleLookup := 'labelstyle_title';
  FTitleLabel.Text := 'RetroTune';
  FSubtitleLabel := TLabel.Create(Self);
  FSubtitleLabel.Parent := Header;
  FSubtitleLabel.Align := TAlignLayout.Bottom;
  FSubtitleLabel.Height := 20;
  FSubtitleLabel.StyleLookup := 'labelstyle_caption';
  FSubtitleLabel.TextSettings.WordWrap := False;
  FSubtitleLabel.TextSettings.Trimming := TTextTrimming.Character;
  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := Page;
  FScroll.Align := TAlignLayout.Client;
  FScroll.ScrollAnimation := TBehaviorBoolean.True;
  // Keep cards clear of the scroll bar, including when the window is narrow.
  FScroll.Padding.Right := 16;
end;

procedure TTuneReferenceForm.AddSection(const Title: string);
begin
  FSection := TLayout.Create(Self);
  FSection.Parent := FScroll.Content;
  FSection.Position.Y := FContentHeight;
  FSection.Align := TAlignLayout.Top;
  FSection.Height := 48;
  FSection.Margins.Bottom := 24;
  var Heading := TLabel.Create(Self);
  Heading.Parent := FSection;
  Heading.Align := TAlignLayout.Top;
  Heading.Height := 24;
  Heading.Margins.Bottom := 8;
  Heading.StyleLookup := 'labelstyle_bodystrong';
  Heading.Text := Translate(Title);
  FCard := TPanel.Create(Self);
  FCard.Parent := FSection;
  FCard.Position.Y := 32;
  FCard.Align := TAlignLayout.Top;
  FCard.Height := 16;
  // Use the WinUI theme's neutral card surface, border and rounded corners.
  FCard.StyleLookup := 'panelstyle';
  FCard.Padding.Left := 16;
  FCard.Padding.Right := 16;
  FCard.Padding.Top := 8;
  FCard.Padding.Bottom := 8;
  FRowCount := 0;
  FContentHeight := FContentHeight + 72;
end;

function TTuneReferenceForm.AddField(const Name, Value: string): TEdit;
const
  RowHeight = 40;
  DividerHeight = 1;
  EditHeight = 32;
begin
  if FRowCount > 0 then
  begin
    var Divider := TPanel.Create(Self);
    Divider.Parent := FCard;
    Divider.Position.Y := FRowCount * (RowHeight + DividerHeight) - DividerHeight;
    Divider.Align := TAlignLayout.Top;
    Divider.Height := DividerHeight;
    Divider.StyleLookup := 'panelstyle_divider';
    FContentHeight := FContentHeight + DividerHeight;
  end;
  var Row := TLayout.Create(Self);
  Row.Parent := FCard;
  Row.Position.Y := FRowCount * (RowHeight + DividerHeight);
  Row.Align := TAlignLayout.Top;
  Row.Height := RowHeight;
  Inc(FRowCount);
  FCard.Height := 16 + FRowCount * RowHeight + (FRowCount - 1) * DividerHeight;
  FSection.Height := 32 + FCard.Height;
  FContentHeight := FContentHeight + RowHeight;
  var LabelName := TLabel.Create(Self);
  LabelName.Parent := Row;
  LabelName.Align := TAlignLayout.Left;
  LabelName.Width := 224;
  LabelName.Margins.Right := 12;
  LabelName.Text := Translate(Name);
  LabelName.TextSettings.WordWrap := False;
  LabelName.TextSettings.Trimming := TTextTrimming.Character;
  LabelName.Hint := Translate(Name);
  Result := TEdit.Create(Self);
  Result.Parent := Row;
  Result.Align := TAlignLayout.Client;
  Result.Margins.Top := (RowHeight - EditHeight) / 2;
  Result.Margins.Bottom := (RowHeight - EditHeight) / 2;
  Result.StyleLookup := 'editstyle_clear_sized';
  Result.ReadOnly := True;
  Result.AutoTranslate := False;
  Result.TextPrompt := Translate('Not specified');
  Result.Text := Value;
  Result.Hint := Value;
end;

procedure TTuneReferenceForm.SetHeading(const Title, Subtitle: string);
begin
  Caption := Translate(Title);
  FTitleLabel.Text := Translate(Title);
  FSubtitleLabel.Text := Subtitle;
  FSubtitleLabel.Hint := Subtitle;
end;

procedure TTuneReferenceForm.ClearContent;
begin
  FCard := nil;
  FSection := nil;
  FScroll.Content.DeleteChildren;
  FContentHeight := 0;
end;

end.