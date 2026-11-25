using System.Windows.Forms;
using System.Xml;
using LiveSplit.Model;
using LiveSplit.UI;
using LiveSplit.UI.Components;

namespace LiveSplit.MuSplit
{
    /// <summary>
    /// Optional. The bridge attaches to LiveSplit on its own (see BridgeHost), so you
    /// don't need this in your layout. It's only here so the component still shows up
    /// under Edit Layout → Control, and adding it does no harm.
    /// </summary>
    public class MuSplitComponent : LogicComponent
    {
        public override string ComponentName => "Mu Split Bridge";

        public MuSplitComponent(LiveSplitState state)
        {
            BridgeHost.Attach(state);
        }

        public override Control GetSettingsControl(LayoutMode mode) => new Label
        {
            Text = $"Mu Split Bridge is always on (127.0.0.1:{BridgeHost.Port}).\nYou don't need to keep it in your layout.",
            AutoSize = true,
            Padding = new Padding(8)
        };

        public override XmlNode GetSettings(XmlDocument document) => document.CreateElement("Settings");
        public override void SetSettings(XmlNode settings) { }
        public override void Update(IInvalidator invalidator, LiveSplitState state, float width, float height, LayoutMode mode) { }
        public override void Dispose() { }   // the bridge lives as long as LiveSplit does
    }
}
