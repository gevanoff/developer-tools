$androidBuildInstallAppId = 'WindowsTools.AndroidBuildInstall'

if ($null -eq ('WindowsTools.TaskbarIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WindowsTools
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;

        public PropertyKey(Guid formatId, uint propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr PointerValue;

        public static PropVariant FromString(string value)
        {
            PropVariant result = new PropVariant();
            result.VariantType = 31; // VT_LPWSTR
            result.PointerValue = Marshal.StringToCoTaskMemUni(value);
            return result;
        }

        public string GetString()
        {
            if (VariantType != 31 || PointerValue == IntPtr.Zero) { return null; }
            return Marshal.PtrToStringUni(PointerValue);
        }

        public void Clear()
        {
            TaskbarIdentity.PropVariantClear(ref this);
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class TaskbarIdentity
    {
        private static readonly Guid PropertyStoreInterface = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        private static readonly Guid AppUserModelFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        private static readonly PropertyKey RelaunchCommand = new PropertyKey(AppUserModelFormat, 2);
        private static readonly PropertyKey RelaunchIconResource = new PropertyKey(AppUserModelFormat, 3);
        private static readonly PropertyKey RelaunchDisplayName = new PropertyKey(AppUserModelFormat, 4);
        private static readonly PropertyKey AppUserModelId = new PropertyKey(AppUserModelFormat, 5);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(
            IntPtr windowHandle,
            ref Guid interfaceId,
            [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHGetPropertyStoreFromParsingName(
            string path,
            IntPtr bindContext,
            uint flags,
            ref Guid interfaceId,
            [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

        [DllImport("ole32.dll")]
        internal static extern int PropVariantClear(ref PropVariant value);

        private static void ThrowIfFailed(int result)
        {
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
        }

        private static void SetString(IPropertyStore store, PropertyKey key, string value)
        {
            PropVariant variant = PropVariant.FromString(value);
            try { ThrowIfFailed(store.SetValue(ref key, ref variant)); }
            finally { variant.Clear(); }
        }

        public static void SetCurrentProcessAppId(string appId)
        {
            ThrowIfFailed(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        public static void SetWindowProperties(
            IntPtr windowHandle,
            string appId,
            string relaunchCommand,
            string displayName,
            string iconResource)
        {
            IPropertyStore store;
            Guid interfaceId = PropertyStoreInterface;
            ThrowIfFailed(SHGetPropertyStoreForWindow(windowHandle, ref interfaceId, out store));
            try
            {
                SetString(store, RelaunchCommand, relaunchCommand);
                SetString(store, RelaunchIconResource, iconResource);
                SetString(store, RelaunchDisplayName, displayName);
                // Set the ID last so the taskbar refresh sees the relaunch properties.
                SetString(store, AppUserModelId, appId);
                ThrowIfFailed(store.Commit());
            }
            finally { if (store != null) { Marshal.ReleaseComObject(store); } }
        }

        public static void SetShortcutAppId(string shortcutPath, string appId)
        {
            IPropertyStore store;
            Guid interfaceId = PropertyStoreInterface;
            const uint ReadWrite = 2;
            ThrowIfFailed(SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, ReadWrite, ref interfaceId, out store));
            try
            {
                SetString(store, AppUserModelId, appId);
                ThrowIfFailed(store.Commit());
            }
            finally { if (store != null) { Marshal.ReleaseComObject(store); } }
        }

        public static string GetShortcutAppId(string shortcutPath)
        {
            IPropertyStore store;
            Guid interfaceId = PropertyStoreInterface;
            ThrowIfFailed(SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, 0, ref interfaceId, out store));
            try
            {
                PropVariant value;
                PropertyKey key = AppUserModelId;
                ThrowIfFailed(store.GetValue(ref key, out value));
                try { return value.GetString(); }
                finally { value.Clear(); }
            }
            finally { if (store != null) { Marshal.ReleaseComObject(store); } }
        }
    }
}
'@
}

function Get-AndroidBuildInstallAppId {
    return $androidBuildInstallAppId
}
