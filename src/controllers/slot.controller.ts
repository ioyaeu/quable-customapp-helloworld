import { Response } from 'express';

class SlotController {
  public handle = async (_req: any, res: Response) => {
    const slot = _req.params?.slot;
    switch (slot) {
      case 'document.page.tab':
        return res.render('pages/document_page_tab.ejs');
      case 'document.action.single':
        return res.render('pages/document_action_single.ejs');
      case 'document.action.bulk':
        return res.render('pages/document_action_bulk.ejs');
      default:
        break;
    }
    return res.render('pages/not_found.ejs');
  };
}

export const slotController = new SlotController();
