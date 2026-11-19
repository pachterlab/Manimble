using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Manimble;

/// Editing a table's cells: one cell typed into on the slide (double-click it), or every cell in the inspector's grid,
/// with rows and columns added or removed there (the Mac's table editor). Either way the table's rows are rewritten in
/// its source with the engine's `table` edit.
public partial class MainWindow
{
    /// The inspector's cell boxes, row by row, for the selected table.
    readonly List<List<TextBox>> tableBoxes = new();
    int? tableOid;

    void ShowTableEditor(int oid, ObjInfo o)
    {
        TableFields.Visibility = Visibility.Visible;
        if (tableOid == oid && tableBoxes.Count > 0 && Draft().Select(r => string.Join("\t", r)).SequenceEqual(o.TableRows().Select(r => string.Join("\t", r)))) return;
        tableOid = oid;
        LayoutTableGrid(o.TableRows());
    }

    void HideTableEditor()
    {
        TableFields.Visibility = Visibility.Collapsed;
        tableOid = null;
        tableBoxes.Clear();
        TableGrid.Children.Clear();
    }

    /// The cells as currently typed (not yet applied).
    List<List<string>> Draft() => tableBoxes.Select(r => r.Select(b => b.Text).ToList()).ToList();

    void LayoutTableGrid(List<List<string>> rows)
    {
        if (rows.Count == 0) rows = new() { new() { "" } };
        int nc = Math.Max(1, rows.Max(r => r.Count));
        TableGrid.Children.Clear();
        TableGrid.RowDefinitions.Clear();
        TableGrid.ColumnDefinitions.Clear();
        tableBoxes.Clear();
        for (int c = 0; c < nc; c++) TableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 56 });
        for (int r = 0; r < rows.Count; r++)
        {
            TableGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var line = new List<TextBox>();
            for (int c = 0; c < nc; c++)
            {
                var box = new TextBox
                {
                    Text = c < rows[r].Count ? rows[r][c] : "", Margin = new Thickness(0, 0, 3, 3), FontSize = 12,
                    ToolTip = $"Row {r + 1}, column {c + 1} · Tab next cell · Enter applies the table",
                };
                if (r == 0) box.FontWeight = FontWeights.SemiBold;
                box.KeyDown += TableCell_KeyDown;
                Grid.SetRow(box, r); Grid.SetColumn(box, c);
                TableGrid.Children.Add(box);
                line.Add(box);
            }
            tableBoxes.Add(line);
        }
    }

    void TableCell_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        ApplyTable(Draft());
        e.Handled = true;
    }

    void TableApply_Click(object sender, RoutedEventArgs e) => ApplyTable(Draft());

    void TableAddRow_Click(object sender, RoutedEventArgs e)
    {
        var d = Draft();
        d.Add(Enumerable.Repeat("", Math.Max(1, d.Count > 0 ? d[0].Count : 1)).ToList());
        LayoutTableGrid(d);
    }

    void TableRemoveRow_Click(object sender, RoutedEventArgs e)
    {
        var d = Draft();
        if (d.Count > 1) { d.RemoveAt(d.Count - 1); LayoutTableGrid(d); }
    }

    void TableAddCol_Click(object sender, RoutedEventArgs e)
    {
        var d = Draft();
        foreach (var r in d) r.Add("");
        LayoutTableGrid(d);
    }

    void TableRemoveCol_Click(object sender, RoutedEventArgs e)
    {
        var d = Draft();
        if (d.Count > 0 && d[0].Count > 1) { foreach (var r in d) if (r.Count > 1) r.RemoveAt(r.Count - 1); LayoutTableGrid(d); }
    }

    /// One cell retyped on the slide: the table's rows with that cell changed.
    void CommitCell(int oid, int row, int col, string text)
    {
        if (scene?.Obj(oid) is not { } o) return;
        var rows = o.TableRows();
        if (row >= rows.Count || col >= rows[row].Count) return;
        rows[row][col] = text;
        if (tableOid == oid && row < tableBoxes.Count && col < tableBoxes[row].Count) tableBoxes[row][col].Text = text;
        ApplyTable(rows, oid);
    }

    void ApplyTable(List<List<string>> rows, int? oid = null)
    {
        if ((oid ?? tableOid) is not int id || scene?.Obj(id) is not { } o) return;
        var current = o.TableRows();
        if (rows.Count == current.Count && rows.Zip(current).All(p => p.First.SequenceEqual(p.Second))) { Toast("The table is unchanged"); return; }
        var arr = new JsonArray();
        foreach (var r in rows) arr.Add(new JsonArray(r.Select(c => (JsonNode?)JsonValue.Create(c)).ToArray()));
        Submit(() => RunEdit(new JsonObject { ["oid"] = id, ["op"] = "table", ["rows"] = arr }));
    }
}
