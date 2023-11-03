#ifndef LNET_RDMA_H
#define LNET_RDMA_H

struct device;
struct page;
enum dma_data_direction;
struct scatterlist;

struct nvfs_dma_rw_ops;

int REGISTER_FUNC (struct nvfs_dma_rw_ops *ops);

void UNREGISTER_FUNC (void);

unsigned int lnet_get_dev_prio(struct device *dev,
			       unsigned int dev_idx);
int lnet_rdma_map_sg_attrs(struct device *dev, struct scatterlist *sg,
			   int nents, enum dma_data_direction direction);
int lnet_rdma_unmap_sg(struct device *dev,
		       struct scatterlist *sg, int nents,
		       enum dma_data_direction direction);
bool lnet_is_rdma_only_page(struct page *page);
unsigned int lnet_get_dev_idx(struct page *page);

/* DMA_ATTR_NO_WARN was added to kernel v4.8-11962-ga9a62c9 */
#ifndef DMA_ATTR_NO_WARN
#define DMA_ATTR_NO_WARN 0
#endif

#endif /* LUSTRE_NVFS_H */

