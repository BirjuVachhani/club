export interface GroupOwner {
  type: 'user' | 'publisher';
  id: string;
  displayName: string;
}

export interface GroupPreviewPackage {
  name: string;
  version: string;
  description: string;
}

export interface PackageGroupSummary {
  id: string;
  slug: string;
  name: string;
  description: string | null;
  owner?: GroupOwner;
  ownerUserId?: string | null;
  publisherId?: string | null;
  packageCount: number;
  previewPackages: GroupPreviewPackage[];
  canManage?: boolean;
}

export interface PackageGroupDetail extends PackageGroupSummary {
  createdAt: string;
  updatedAt: string;
}
