export type Segment='postpaid'|'mbb'|'bb';
export const segments:Segment[]=['postpaid','mbb','bb'];
export const segmentNames:Record<Segment,string>={postpaid:'Postpaid',mbb:'MBB',bb:'Broadband'};
export function classify(value:string):Segment|null{
  const v=value.trim().toLowerCase();
  if(v==='cons postpaid'||v==='hac')return 'postpaid';
  if(v==='hbb')return 'mbb';
  if(v==='hbb-5g'||v==='fiber - ftth')return 'bb';
  return null;
}
export function daysInMonth(month:string){const [year,m]=month.split('-').map(Number);return new Date(year,m,0).getDate()}
export function project(actual:number,asOf:string,month:string){if(!asOf||!asOf.startsWith(month))return 0;const day=Number(asOf.slice(8,10));return day>0?actual/day*daysInMonth(month):0}
export function rate(value:number,target:number){return target>0?value/target*100:0}
export function rating(value:number){return value>=90?'Excellent':value>=85?'Good':value>=75?'Decent':'Below pace'}
