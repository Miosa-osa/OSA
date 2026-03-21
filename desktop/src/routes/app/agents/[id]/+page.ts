import type { PageLoad } from "./$types";

export const ssr = false;

export const load: PageLoad = ({ params }) => ({ agentId: params.id });
