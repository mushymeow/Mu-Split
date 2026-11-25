using System;
using LiveSplit.Model;
using LiveSplit.UI.Components;

[assembly: ComponentFactory(typeof(LiveSplit.MuSplit.MuSplitFactory))]

namespace LiveSplit.MuSplit
{
    public class MuSplitFactory : IComponentFactory
    {
        // LiveSplit creates every component factory at startup (for the layout editor
        // and update checks), so this is our hook to attach without being in a layout.
        public MuSplitFactory()
        {
            BridgeHost.EnsureStarted();
        }

        public string ComponentName => "Mu Split Bridge";
        public string Description => "Streams timer state to an external Love2D front-end and accepts commands back.";
        public ComponentCategory Category => ComponentCategory.Control;

        public IComponent Create(LiveSplitState state) => new MuSplitComponent(state);

        // Auto-update plumbing (unused for the test build)
        public string UpdateName => ComponentName;
        public string XMLURL => "";
        public string UpdateURL => "";
        public Version Version => new Version(0, 1, 0);
    }
}
