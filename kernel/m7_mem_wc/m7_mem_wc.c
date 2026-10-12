// SPDX-License-Identifier: GPL-2.0
/*
 * Restricted write-combined mapping for the SNES HD Mode 7 pixel buffers.
 *
 * Ported from NDS4MiSTer's kernel/nds_mem_wc: Normal non-cacheable /
 * write-combined mappings avoid the per-word AXI serialization imposed by
 * ARM /dev/mem Device memory when the daemon publishes 448 KiB of pixels
 * per frame. This node accepts mmap() only inside the two Mode 7 pixel
 * buffers ([M7_PIXBUF_BASE, M7_PIXBUF_BASE + 2*M7_PIXBUF_BYTES) per
 * docs/m7_abi.md). The mailbox header, per-line registers, ctrl word and
 * VRAM/CGRAM images are deliberately excluded so their Device-memory
 * ordering semantics (pixel data before ctrl-word publish) cannot change.
 */

#include <linux/fs.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/version.h>

#define M7_MEM_WC_NAME "m7_mem_wc"

/* Keep in sync with rtl/m7_abi.svh / daemon/m7_abi.h (scripts/check_abi.sh). */
#define M7_PIXBUF_PHYS_BASE 0x3E002000UL
#define M7_PIXBUF_BYTES     0x00070000UL
#define M7_WC_WINDOW_SIZE   (2UL * M7_PIXBUF_BYTES) /* ping-pong pair, contiguous */

static int m7_mem_wc_mmap(struct file *file, struct vm_area_struct *vma)
{
	const size_t size = vma->vm_end - vma->vm_start;
	const phys_addr_t offset = (phys_addr_t)vma->vm_pgoff << PAGE_SHIFT;
	const phys_addr_t limit =
		(phys_addr_t)M7_PIXBUF_PHYS_BASE + M7_WC_WINDOW_SIZE;

	if (!size || offset + size < offset ||
	    offset < M7_PIXBUF_PHYS_BASE || offset + size > limit)
		return -EPERM;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
	vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#else
	vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#endif
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	if (remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff,
			    size, vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

static const struct file_operations m7_mem_wc_fops = {
	.owner = THIS_MODULE,
	.mmap = m7_mem_wc_mmap,
	.llseek = noop_llseek,
};

static struct miscdevice m7_mem_wc_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = M7_MEM_WC_NAME,
	.fops = &m7_mem_wc_fops,
	.mode = 0600,
};

static int __init m7_mem_wc_init(void)
{
	int result = misc_register(&m7_mem_wc_device);

	if (result)
		return result;
	pr_info("m7_mem_wc: restricted window [0x%lx, 0x%lx)\n",
		M7_PIXBUF_PHYS_BASE, M7_PIXBUF_PHYS_BASE + M7_WC_WINDOW_SIZE);
	return 0;
}

static void __exit m7_mem_wc_exit(void)
{
	misc_deregister(&m7_mem_wc_device);
}

module_init(m7_mem_wc_init);
module_exit(m7_mem_wc_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Restricted write-combined SNES HD Mode 7 pixel window");
