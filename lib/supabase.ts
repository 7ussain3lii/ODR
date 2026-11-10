import {createClient} from '@supabase/supabase-js';
export function browserClient(){return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!)}
export function tabsEmail(tabs:string){return `${tabs.trim().toUpperCase()}@tabs.target-update.invalid`}
