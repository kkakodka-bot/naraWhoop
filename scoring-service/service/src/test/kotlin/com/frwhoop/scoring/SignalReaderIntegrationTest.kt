package com.frwhoop.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import org.junit.Assert.*
import org.junit.Test

class SignalReaderIntegrationTest : PgIntegrationBase() {
    @Test fun canonicalWhoop5WindowExcludesLegacyOtherChannelAndSuspectRows() {
        sql("""insert into noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
            values ('$u','$device','$u',100,800,0,0,5,0,'$u'),
                   ('$u','$device','$u',100,820,0,1,5,0,'$u'),
                   ('$u','$device','$u',100,900,0,0,7,0,'$u'),
                   ('$u','$device','$u',100,400,0,null,null,0,'$u'),
                   ('$u','$device','$u',101,810,0,0,5,1,'$u'),
                   ('$u','$device','$u',101,830,0,0,110,0,'$u')""")
        val reader=SignalSampleReader(pg.db)
        val rr=pg.db.withConnection { reader.loadRr(it,u,device.toString(),100,101) }
        assertEquals(listOf(800,820),rr.map { it.rrMs })
        assertEquals(listOf(0,1),rr.map { it.ord })
        assertEquals("6",scalar("select count(*) from noop_rr_intervals"))
    }

    @Test fun whoop4RetainsUnlabelledBeatsButRejectsSuspectAndSpo2Ibi() {
        sql("update devices set device_family='whoop4' where id='$device'")
        sql("""insert into noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
            values ('$u','$device','$u',100,800,0,null,null,0,'$u'),
                   ('$u','$device','$u',100,820,0,0,2,0,'$u'),
                   ('$u','$device','$u',100,840,0,0,null,1,'$u')""")
        val reader=SignalSampleReader(pg.db)
        assertEquals(listOf(800),pg.db.withConnection { reader.loadRr(it,u,device.toString(),100,101) }.map { it.rrMs })
    }

    @Test fun fullDayInputIncludesAfternoonAndTimezoneProvenance() {
        sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            values('$u','$device','$u',extract(epoch from timestamptz '$day 18:00:00Z'),70,'$u')""")
        val inputs=SignalSampleReader(pg.db).loadDay(u,day,device)!!
        assertEquals(1,inputs.hr.size); assertEquals(inputs.dayHi,inputs.nightHi)
        assertEquals("UTC",inputs.timezone)
    }
}
