#!/bin/bash

sudo apt install build-essential libncurses5-dev fakeroot xz-utils libelf-dev liblz4-tool \
  unzip flex bison bc debhelper rsync pahole libssl-dev:native

wget -N https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.47.tar.xz
tar -xvf linux-6.1.47.tar.xz
cd linux-6.1.47

patch -p1 << EOM
diff -ruN a/Documentation/admin-guide/kernel-parameters.txt b/Documentation/admin-guide/kernel-parameters.txt
--- a/Documentation/admin-guide/kernel-parameters.txt
+++ b/Documentation/admin-guide/kernel-parameters.txt
@@ -4190,6 +4190,15 @@
 		nomsi		[MSI] If the PCI_MSI kernel config parameter is
 				enabled, this kernel boot option can be used to
 				disable the use of MSI interrupts system-wide.
+		pcie_acs_override =
+					[PCIE] Override missing PCIe ACS support for:
+				downstream
+					All downstream ports - full ACS capabilities
+				multfunction
+					All multifunction devices - multifunction ACS subset
+				id:nnnn:nnnn
+					Specfic device - full ACS capabilities
+					Specified as vid:did (vendor/device ID) in hex
 		noioapicquirk	[APIC] Disable all boot interrupt quirks.
 				Safety option to keep boot IRQs enabled. This
 				should never be necessary.
diff -ruN a/drivers/pci/quirks.c b/drivers/pci/quirks.c
--- a/drivers/pci/quirks.c
+++ b/drivers/pci/quirks.c
@@ -4603,6 +4603,107 @@
 	return false;
 }
 
+static bool acs_on_downstream;
+static bool acs_on_multifunction;
+
+#define NUM_ACS_IDS 16
+struct acs_on_id {
+	unsigned short vendor;
+	unsigned short device;
+};
+static struct acs_on_id acs_on_ids[NUM_ACS_IDS];
+static u8 max_acs_id;
+
+static __init int pcie_acs_override_setup(char *p)
+{
+	if (!p)
+		return -EINVAL;
+
+	while (*p) {
+		if (!strncmp(p, "downstream", 10))
+			acs_on_downstream = true;
+		if (!strncmp(p, "multifunction", 13))
+			acs_on_multifunction = true;
+		if (!strncmp(p, "id:", 3)) {
+			char opt[5];
+			int ret;
+			long val;
+
+			if (max_acs_id >= NUM_ACS_IDS - 1) {
+				pr_warn("Out of PCIe ACS override slots (%d)\n",
+						NUM_ACS_IDS);
+				goto next;
+			}
+
+			p += 3;
+			snprintf(opt, 5, "%s", p);
+			ret = kstrtol(opt, 16, &val);
+			if (ret) {
+				pr_warn("PCIe ACS ID parse error %d\n", ret);
+				goto next;
+			}
+			acs_on_ids[max_acs_id].vendor = val;
+
+			p += strcspn(p, ":");
+			if (*p != ':') {
+				pr_warn("PCIe ACS invalid ID\n");
+				goto next;
+			}
+
+			p++;
+			snprintf(opt, 5, "%s", p);
+			ret = kstrtol(opt, 16, &val);
+			if (ret) {
+				pr_warn("PCIe ACS ID parse error %d\n", ret);
+				goto next;
+			}
+			acs_on_ids[max_acs_id].device = val;
+			max_acs_id++;
+		}
+next:
+		p += strcspn(p, ",");
+		if (*p == ',')
+			p++;
+	}
+
+	if (acs_on_downstream || acs_on_multifunction || max_acs_id)
+		pr_warn("Warning: PCIe ACS overrides enabled; This may allow non-IOMMU protected peer-to-peer DMA\n");
+
+	return 0;
+}
+early_param("pcie_acs_override", pcie_acs_override_setup);
+
+static int pcie_acs_overrides(struct pci_dev *dev, u16 acs_flags)
+{
+	int i;
+
+	/* Never override ACS for legacy devices or devices with ACS caps */
+	if (!pci_is_pcie(dev) ||
+		pci_find_ext_capability(dev, PCI_EXT_CAP_ID_ACS))
+			return -ENOTTY;
+
+	for (i = 0; i < max_acs_id; i++)
+		if (acs_on_ids[i].vendor == dev->vendor &&
+			acs_on_ids[i].device == dev->device)
+				return 1;
+
+	switch (pci_pcie_type(dev)) {
+	case PCI_EXP_TYPE_DOWNSTREAM:
+	case PCI_EXP_TYPE_ROOT_PORT:
+		if (acs_on_downstream)
+			return 1;
+		break;
+	case PCI_EXP_TYPE_ENDPOINT:
+	case PCI_EXP_TYPE_UPSTREAM:
+	case PCI_EXP_TYPE_LEG_END:
+	case PCI_EXP_TYPE_RC_END:
+		if (acs_on_multifunction && dev->multifunction)
+			return 1;
+	}
+
+	return -ENOTTY;
+}
+
 /*
  * Many Intel PCH Root Ports do provide ACS-like features to disable peer
  * transactions and validate bus numbers in requests, but do not provide an
@@ -5002,6 +5103,7 @@
 	{ PCI_VENDOR_ID_ZHAOXIN, PCI_ANY_ID, pci_quirk_zhaoxin_pcie_ports_acs },
 	/* Wangxun nics */
 	{ PCI_VENDOR_ID_WANGXUN, PCI_ANY_ID, pci_quirk_wangxun_nic_acs },
+	{ PCI_ANY_ID, PCI_ANY_ID, pcie_acs_overrides },
 	{ 0 }
 };
EOM

LOCALVERSION=-acso make olddefconfig -j`nproc` bindeb-pkg
